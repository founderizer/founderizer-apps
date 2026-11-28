import AppKit
import FleetCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The file whose card shows over the page, by its path.
private struct KnowledgeCardID: Identifiable { let id: String }

/// Settings › Knowledge: the owner's files and pages (`knowledge/owner/` in the fleet repository), with a filter,
/// Add file (a picker, or files dropped here) and Add URL. **A file's row is a Secrets row** (the owner's yes of 28
/// October 2026 to D-5): its mark, its title and the agents that read it ("Atlas, Nova", or "No agent"); the row opens
/// the file's text, and its ⓘ the file's card — the agents that read it and the ones that do not, each with its − or
/// its +, and Delete. It was nine agent chips and a Delete under every file: 47 controls on one page.
///
/// It is the same relation an agent's own Knowledge shows from its end, and it writes the same thing: the "Knowledge
/// files" section of that agent's profile. No list here shows an internal knowledge file; a badge in a request's words
/// opens one read-only, on a hub that gives the app one (`internalOpened`, owner API 1.278).
///
/// **An agent's own Knowledge is a group of its Can use** (`grouped`, D-5: one editor for each kind): the files that
/// agent reads, in the same rows, each of which opens the same card, with a − that takes it back from that agent, the +
/// of its heading that gives it one more, and the empty card when it reads none (the owner's yes of 3 November 2026).
struct KnowledgePage: View {
    @Bindable var store: FleetStore
    /// One agent's own: only the files it reads. nil is the fleet's own list.
    var agent: String?
    /// A group of the agent's Can use: the heading with its +, and the rows with their −, or the empty card when the
    /// agent reads no file.
    var grouped = false
    @State private var opened: String?
    @Environment(\.colorSchemeContrast) private var contrast
    /// The file whose card shows over the page.
    @State private var carded: KnowledgeCardID?
    @State private var filter = ""
    /// The fleet's profiles for the chips. Each agent page filters this same response.
    private var profiles: [AgentProfile]? {
        store.reading(Self.profilesName)
    }
    @State private var addingURL = false
    @State private var address = ""
    /// The change that waits for the hub, in words.
    @State private var busy: String?
    @State private var message: (text: String, warning: Bool)?
    /// The system's own words for the last change or read the hub did not answer: behind its line, never in it.
    @State private var cause: String?
    /// The file whose Delete waits for the owner's confirmation.
    @State private var deleting: String?
    @State private var dropping = false
    /// The rows of the opened file whose words can be selected (a block, or a cell of a table): the row under the
    /// pointer and the row whose words he pressed last (`MessageText.selection`).
    @State private var selection = ChatSelection()
    /// The opened file's text, or the reason that it is not there. The text is the store's: the last file he read on
    /// this page shows in the first frame when he opens it again.
    private var file: KnowledgeFile? {
        get { store.reading("knowledge.file.\(scope)") } nonmutating set { store.keep(newValue, as: "knowledge.file.\(scope)") }
    }
    @State private var fileError: String?
    /// The read of the file under the pointer, before its click (`readAhead`).
    @State private var ahead: Task<Void, Never>?
    /// **The opened file's text in the app's text box** (owner feature `knowledge_edit`; the owner's yes of 5 November
    /// 2026 to "Pencil, then edit"): nil while the page shows the formatted text. The box saves itself when it loses
    /// the cursor, on the check mark and when the page goes away, as a role's words do (`RolePage`).
    @State private var draft: KnowledgeEdit?
    @State private var saveState: SaveState?
    /// Why the last save of the box did not go, in the hub's words: the orange line under the box.
    @State private var problem: String?
    /// The save on its way: the next one waits for it, so two saves of one text never race.
    @State private var sending: Task<Void, Never>?
    /// The text that the hub took last, by file: a save after it compares with this, so the cursor that leaves the box
    /// and the check mark after it send the text once (the hub refuses the same text again).
    @State private var taken: [String: String] = [:]
    @FocusState private var typing: Bool
    /// **The key-like parts that he chose to keep in the box** ("Keep it", "Paste it anyway"): no second question for
    /// them, and their save names them to the hub (`settle`, `key_kept`). Any other key still asks: until 24 November
    /// 2026 one choice let every key through until a check read none, so a second key that came whole (a menu paste, a
    /// drop) while the kept save was on its way, after it failed, or as the first change after it, went with no
    /// question (the coordinator's S2).
    @State private var keptKeys: Set<String> = []
    /// **The parts that the strip's check found when it asked** (`ask`): "Keep it" keeps these, and only these, so a
    /// part that came in whole after the strip came up (a menu paste, a drop) asks again (round 2 of 24 November 2026).
    @State private var asked: Set<String> = []
    /// **The hub and the generation of the box's text**, from the moment that it opened: its saves go there and
    /// nowhere else, also after the app moved to another hub or generation (round 2: the old generation's text could
    /// replace the same path in the new one).
    @State private var home: KnowledgeHome?
    /// The height of the question of a key under the box, with the space over it: the box gives it up while the
    /// question shows, so that the question stands on the page and not under its edge.
    @State private var keyStrip: CGFloat = 0
    /// The key-like parts of the hub's text of the open file (`KeyInText.all`), read once for each such text: the guard
    /// asks only about a key that his edit adds to it.
    @State private var savedKeys: (text: String, keys: Set<String>)?
    /// **His unsent text of a file whose save a key held when the page went away, in memory only** (as his words under
    /// a request's card, `NeedAnswerBox.clarifyDrafts`): the file gives it back in the box, with its question, when it
    /// opens again, on the hub's text that it began from (`giveBack`). Never on the disk, because the key is in it. By
    /// the hub, its generation and the file. It is given back once, and goes with its file, its hub's generation and a
    /// change of the hub's text; a text that is saved, or that is the hub's text again, is never kept here.
    @MainActor private static var heldDrafts: [String: HeldText] = [:]
    /// His held text, and the number of the last save of the box that was queued before it was held (`queue`): the
    /// saves on their way then, whose landing moves the text that it began from (`send`).
    private struct HeldText {
        var edit: KnowledgeEdit
        let after: Int
        /// The text that it began from is not known: a save that the hub refused for a key, whose file could not be
        /// read again. It comes back on the text that the file has then, so his words are not lost (round 3).
        var anyBase = false
    }
    /// A hub, one generation of its database, and whether that hub checked a file for a key when the box opened
    /// (`checksKnowledgeKeys`): a save of the box says `key_kept` to that hub also after the app moved on (round 3).
    private struct KnowledgeHome: Equatable {
        let hub: URL
        let db: String
        let keyCheck: Bool
    }
    /// **The saves of the box that are on their way, by file** (`heldDraftKey`): the pencil waits for them, so the
    /// box never opens on the text from before a save that has not landed (round 3: it opened on it, and a later save
    /// put that old text over his edit, or a refusal of the save found the old text in the box and held nothing).
    @MainActor private static var onTheWay: [String: Int] = [:]
    /// A save of the box ended: the pencil reads `onTheWay` again.
    @State private var saveEnded = 0
    /// The file whose reader the page shows: a save refused for a key gives his words back at once only there.
    @State private var readerShows: String?
    /// **The file whose reader reads it before giving back his held words** (`giveBack`), until a read of it ends well:
    /// while words of his wait for that file, the pencil waits for that read (round 6). The page shows the text that
    /// it read last at once, so the pencil opened the box on it, the held words stayed in memory, and his next save
    /// dropped them.
    @State private var readerReading: String?
    /// **A test's pause in each read of the box's words, before the read**: it puts a save's landing between a press and
    /// its read (`KnowledgeKeyHoldTests`). nil in the app.
    @MainActor static var readPause: (@Sendable () -> Void)?
    /// The parts that the words of the box add to the hub's text, as last read off the main thread (`addedKeys`): a
    /// save of words that were read already needs no second read, and the check mark closes the box at once.
    @State private var checked: (text: String, saved: String, keys: [Substring])?
    private let client = KnowledgeClient()
    /// The most text that the reader shows: the Markdown view makes every block at once.
    private static let readerLimit = 100_000
    /// The profiles, read before the page first opens (`PagePrefetch`): the fleet's page's, and each agent's.
    nonisolated static let profilesName = "knowledge.profiles.fleet"
    static let prefetch = PagePrefetch(profilesName, feature: "profiles", sharedAcrossAgents: true) {
        try await HubClient().profiles(hub: $0, database: $1).profiles
    }

    private var scope: String { agent ?? "fleet" }
    private var offered: Bool { store.state?.ui_features?.contains(KnowledgeClient.feature) == true }
    private var canChange: Bool { offered && store.writesNow && busy == nil }
    /// The agent's profile, on one agent's page; nil until it is read.
    private var profile: AgentProfile? { agent.flatMap { name in profiles?.first { $0.agent == name } } }
    /// The files the agent of this page reads, by path.
    private var mine: Set<String> { Set(profile.flatMap { KnowledgeAccess.paths($0.sections) } ?? []) }

    var body: some View {
        let entries = store.state?.knowledge
        Group {
            if let entry = entries?.first(where: { $0.path == opened }) ?? internalOpened { reader(entry) } else { list(entries) }
        }
        .task(id: "\(store.hub)/\(store.state?.db ?? "")") { await poll() }
        // a file asked while this page already shows (its poll takes one only when it starts)
        .onChange(of: store.knowledgeRead) {
            if agent == nil, let path = store.knowledgeRead { store.knowledgeRead = nil; opened = path }
        }
    }

    /// An agent's internal file that a badge in a request's words opened (`FleetStore.openCardLink`), on a hub that gives
    /// the app one: the reader shows it read-only, with no pencil (`readerActions`), and no list of this page shows it
    /// (the owner's "Yes, read-only", 20 November 2026).
    private var internalOpened: KnowledgeEntry? {
        guard agent == nil, let opened, store.state?.readsInternalKnowledge == true else { return nil }
        return store.state?.internalKnowledge?.first { $0.path == opened }
    }

    // MARK: list

    private func list(_ entries: [KnowledgeEntry]?) -> some View {
        let words = filter.trimmingCharacters(in: .whitespaces).lowercased()
        // One agent's page lists the files that agent reads; until its profile is read, it lists none.
        let scoped = agent == nil ? entries : profiles == nil ? nil : entries?.filter { mine.contains($0.path) }
        let shown = (scoped ?? []).filter { entry in
            words.isEmpty || [entry.title, entry.path, entry.source ?? ""].contains { $0.lowercased().contains(words) }
        }
        return Group {
            if grouped {
                // The agent's files under their heading, with the + that gives it one more and a − on each: a row
                // opens the file's card. An agent that reads none has the empty card.
                VStack(alignment: .leading, spacing: FleetSpace.inside) {
                    FormSection("Knowledge") {
                        if offered, let scoped {
                            if scoped.isEmpty { FormEmpty("No files", symbol: "books.vertical") }
                            ForEach(scoped) { agentRow($0) }
                        }
                    } accessory: {
                        if offered, scoped != nil { giveMenu(entries ?? []) }
                    }
                    if offered, scoped == nil, entries != nil, store.connectionError == nil { LoadingLine(String(l10n: "Reading the profile…")) }
                    // **Only a refusal, in the hub's words** (UI-PATTERNS: a footer carries what went wrong and nothing
                    // else): a + or a − that worked shows itself in the list. Under the card it is the card's.
                    if carded == nil, message?.warning == true { status }
                }
            } else {
                FleetPage("Knowledge") {
                    if (scoped?.count ?? 0) > 1 { filterField }
                    if addingURL && offered { urlForm }
                    status
                    if !offered {
                        FormSection { FormEmpty("This hub does not keep your knowledge files yet.", symbol: "books.vertical") }
                    } else if let scoped {
                        if scoped.isEmpty {
                            FormSection { FormEmpty("No files yet", symbol: "books.vertical") }
                        } else if shown.isEmpty {
                            FormSection { FormEmpty("No file matches the filter.", symbol: "magnifyingglass") }
                        } else {
                            FormSection { ForEach(shown) { row($0) } }
                        }
                    }
                } actions: {
                    if offered {
                        Button { addingURL = true; message = nil } label: { Label("Add URL", systemImage: "link") }
                            .buttonStyle(FleetOutlineButtonStyle()).disabled(!canChange || addingURL).accessibilityIdentifier("knowledge-add-url")
                        Button { chooseFiles() } label: { Label("Add file", systemImage: "plus") }
                            .buttonStyle(FleetPrimaryButtonStyle()).disabled(!canChange).accessibilityIdentifier("knowledge-add-file")
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard canChange, !urls.isEmpty else { return false }
                    Task { await add(urls) }
                    return true
                } isTargeted: { dropping = $0 && canChange }
                .overlay {
                    if dropping {
                        RoundedRectangle(cornerRadius: FormMetrics.radius).strokeBorder(FleetStyle.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                            .padding(10).allowsHitTesting(false)
                    }
                }
            }
        }
        .fleetModal(item: $carded) { card($0.id, entries: entries ?? []) }
    }

    // MARK: a file's card

    /// **A file's card**, the one editor of who reads it, over the page from the fleet's row and from an agent's (the
    /// owner, 3 November 2026: "much easier to understand which agents have access to it and which ones dont! ... a
    /// larger modal with 2 sections ... icons instead of text"): its mark and title, when and from what it came in
    /// (`KnowledgeOrigin`, the whole source on hover), the eye that opens its text, then the agents that read it, each
    /// with a −, beside the ones that do not, each with a + — which adds the file to that agent's profile or takes it
    /// out — and Delete, behind the one confirmation it has. Done, Esc or a click outside closes it.
    private func card(_ path: String, entries: [KnowledgeEntry]) -> some View {
        let entry = entries.first { $0.path == path }
        let readers = Set(entry.map { users(of: $0).map(\.agent) } ?? [])
        let agents = store.state?.agents.map(\.name) ?? []
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                IconTile(symbol: entry?.source?.hasPrefix("http") == true ? "globe" : "doc.text")
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry?.title ?? path).font(FormMetrics.title).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled).accessibilityAddTraits(.isHeader)
                    if let origin = entry?.origin {
                        Text(origin.line()).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                            .lineLimit(1).truncationMode(.tail).help(origin.source)
                            .accessibilityIdentifier("knowledge-card-origin")
                    }
                }
                Spacer(minLength: 12)
                if let entry {
                    IconButton(symbol: "eye", words: String(l10n: "Read \(entry.title)")) { readText(entry) }
                        .accessibilityIdentifier("knowledge-card-read")
                }
                Button("Done") { carded = nil }.buttonStyle(FleetOutlineButtonStyle()).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("knowledge-card-done")
            }
            if let entry {
                // Side by side while the card is wide enough, and one over the other where it is not.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) { readerLists(entry, agents: agents, readers: readers) }
                    VStack(alignment: .leading, spacing: 18) { readerLists(entry, agents: agents, readers: readers) }
                }
                status
                if deleting == entry.path {
                    confirmation(entry)
                } else {
                    Button("Delete", role: .destructive) { deleting = entry.path; message = nil }
                        .buttonStyle(FleetDangerButtonStyle()).disabled(!canChange)
                        .help("Delete \(entry.title) from your knowledge").accessibilityIdentifier("knowledge-card-delete")
                }
            } else {
                Text("This file is no longer in the list.").font(FormMetrics.text).foregroundStyle(FleetStyle.muted)
            }
        }
        .padding(22).frame(width: Self.cardWidth)
        .font(FleetStyle.body).foregroundStyle(FleetStyle.text)
    }

    /// The file's card is wider than the other cards over a page (560): it holds two lists side by side.
    private static let cardWidth: CGFloat = 720

    /// The card's two lists: the agents that read the file, each with a −, and the ones that do not, each with a +.
    /// The agent's glyph before its name, as on every card's agent rows (the owner, 30 October 2026: "Marks on every
    /// agent row"; margins row 15).
    @ViewBuilder private func readerLists(_ entry: KnowledgeEntry, agents: [String], readers: Set<String>) -> some View {
        let reading = agents.filter { readers.contains($0) }, notReading = agents.filter { !readers.contains($0) }
        FormSection("Reads it · \(reading.count)") {
            if reading.isEmpty { FormEmpty("No agent reads it", symbol: "person.slash") }
            ForEach(reading, id: \.self) { name in
                FormRow(name.agentLabel, mark: AgentGlyph(name: name, size: GlyphSize.inline)) {
                    IconButton(symbol: "minus", words: String(l10n: "Take \(entry.title) from \(name.agentLabel)")) {
                        Task { await setAvailable(false, entry: entry, agent: name) }
                    }
                    .disabled(!canChange || profiles?.contains { $0.agent == name } != true)
                    .accessibilityIdentifier("knowledge-card-remove-\(name)")
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
        FormSection("Does not read it · \(notReading.count)") {
            if notReading.isEmpty { FormEmpty("Every agent reads it", symbol: "person.3") }
            ForEach(notReading, id: \.self) { name in
                FormRow(name.agentLabel, mark: AgentGlyph(name: name, size: GlyphSize.inline)) {
                    IconButton(symbol: "plus", words: String(l10n: "Give \(entry.title) to \(name.agentLabel)")) {
                        Task { await setAvailable(true, entry: entry, agent: name) }
                    }
                    .disabled(!canChange || profiles?.contains { $0.agent == name } != true)
                    .accessibilityIdentifier("knowledge-card-give-\(name)")
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// **The eye of a file's card opens its text**: on the fleet's page, its reader here; from an agent's Can use, the
    /// reader of Settings › Knowledge, which takes the file from the store when it shows (`FleetStore.knowledgeRead`).
    private func readText(_ entry: KnowledgeEntry) {
        carded = nil; deleting = nil; message = nil
        if agent == nil {
            opened = entry.path
        } else {
            store.knowledgeRead = entry.path
            store.destination = .settings(.knowledge)
        }
    }

    /// **The + of an agent's Knowledge** (the owner's yes of 3 November 2026): the fleet's files that this agent does not
    /// read, in the app's list; one choice adds it to the agent's profile, as the + of its card does. Only while there is
    /// one to give and the hub answers; it waits while a change goes on.
    @ViewBuilder private func giveMenu(_ entries: [KnowledgeEntry]) -> some View {
        let open = entries.filter { !mine.contains($0.path) }
        if let agent, profile != nil, store.writesNow, !open.isEmpty {
            let words = String(l10n: "Give \(agent.agentLabel) a file")
            FleetSelect(words, options: open.map { FleetOption($0.path, $0.title, mark: .symbol(Self.symbol($0))) }) { path in
                guard let entry = open.first(where: { $0.path == path }) else { return }
                Task { await setAvailable(true, entry: entry, agent: agent) }
            } label: {
                Image(systemName: "plus").font(IconMetrics.symbol(13)).foregroundStyle(FleetStyle.muted)
            }
            .buttonStyle(FleetIconButtonStyle())
            .disabled(!canChange)
            .help(words)
            // In the column of the rows' −, which stand the rows' inset in from the card's edge.
            .padding(.trailing, FormMetrics.rowInset)
            .accessibilityIdentifier("knowledge-give")
        }
    }

    /// A file's mark: a globe for a page the hub reads, a document for every other file.
    private static func symbol(_ entry: KnowledgeEntry) -> String { entry.source?.hasPrefix("http") == true ? "globe" : "doc.text" }

    /// **The app's one field look, whose whole box takes the click** (T-30, T-21; fix round 2): it was a capsule of its
    /// own whose edge read 1.45:1, and only its 16-pt line of words took the click.
    private var filterField: some View {
        TextField(text: $filter, prompt: Text(verbatim: "")) { Text("Filter files") }
            .fieldPlaceholder(String(l10n: "Filter files"), shows: filter.isEmpty).fleetField().frame(width: 180)
            .accessibilityIdentifier("knowledge-filter")
    }

    @ViewBuilder private var status: some View {
        if let busy {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy) }
                .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).accessibilityIdentifier("knowledge-busy")
        } else if let message {
            Text(message.text).font(FormMetrics.detail).foregroundStyle(message.warning ? .orange : FleetStyle.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("knowledge-status")
                .help(behind(message.text)).accessibilityValue(behind(message.text))
        }
    }

    private var urlForm: some View {
        FormSection("Add a web page", footer: String(l10n: "The hub reads the page and keeps its text with the address and the date. It reads the page again every day and keeps the new text when it changed. Only public pages.")) {
            HStack(spacing: 8) {
                TextField(text: $address, prompt: Text(verbatim: "")) { Text("https://example.com/page") }
                    .fieldPlaceholder("https://example.com/page", shows: address.isEmpty).fleetField()
                    .onSubmit { Task { await addPage() } }.accessibilityIdentifier("knowledge-url")
                Button("Add") { Task { await addPage() } }.buttonStyle(FleetOutlineButtonStyle())
                    .disabled(!canChange || Self.pageAddress(address) == nil)
                Button("Cancel") { addingURL = false; address = "" }.buttonStyle(FleetOutlineButtonStyle()).disabled(busy != nil)
            }.padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 10)
        }
    }

    /// The agents that read a file, in the words of every list of the app: up to three names, else their count, or
    /// "No agent".
    private func readers(_ entry: KnowledgeEntry) -> String { agentWords(users(of: entry).map(\.agent)) }

    /// On an agent's own list, the other agents that read the file, or nil when it is this agent's alone.
    private func otherReaders(_ entry: KnowledgeEntry) -> String? {
        let others = users(of: entry).map(\.agent).filter { $0 != agent }
        return others.isEmpty ? nil : agentWords(others)
    }

    /// One file on the fleet's page: its mark, its title and the agents that read it, which open its text, and its ⓘ,
    /// which opens its card.
    private func row(_ entry: KnowledgeEntry) -> some View {
        HStack(spacing: 12) {
            Button { opened = entry.path } label: {
                HStack(spacing: 12) {
                    IconTile(symbol: entry.source?.hasPrefix("http") == true ? "globe" : "doc.text")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(1)
                        Text(readers(entry)).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("Read \(entry.title)").accessibilityIdentifier("knowledge-\(entry.path)")
                .onHover { readAhead(entry, under: $0) }
            IconButton(symbol: "info.circle", words: String(l10n: "Show who reads \(entry.title)"), size: 14) {
                message = nil; deleting = nil; carded = KnowledgeCardID(id: entry.path)
            }.accessibilityIdentifier("knowledge-info-\(entry.path)")
        }
        .padding(.horizontal, FormMetrics.rowInset).frame(minHeight: FormMetrics.twoLineRow)
    }

    /// One file of an agent's Can use: the same row, whose click opens the file's card, as a secret's row does, and at
    /// its end the − that takes the file back from this agent alone (the owner's yes of 3 November 2026). The − stands
    /// over the row, never inside its button, so its click is its own.
    private func agentRow(_ entry: KnowledgeEntry) -> some View {
        Button { message = nil; deleting = nil; carded = KnowledgeCardID(id: entry.path) } label: {
            HStack(spacing: 12) {
                IconTile(symbol: Self.symbol(entry))
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(1)
                    // The other agents that read it: this agent reads every file of its own list (the owner, 13
                    // November 2026: "review all other pages for the same issues!!").
                    if let others = otherReaders(entry) {
                        Text(others).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                    }
                }.padding(.vertical, 10)
                Spacer(minLength: 12)
                Color.clear.frame(width: IconMetrics.side, height: IconMetrics.side)
            }.padding(.horizontal, FormMetrics.rowInset)
                .frame(minHeight: otherReaders(entry) == nil ? FormMetrics.row : FormMetrics.twoLineRow)
        }
        .buttonStyle(FleetRowButtonStyle())
        .help("Show who reads \(entry.title)")
        .accessibilityIdentifier("knowledge-\(entry.path)")
        .overlay(alignment: .trailing) {
            if let agent {
                IconButton(symbol: "minus", words: String(l10n: "Take \(entry.title) back from \(agent.agentLabel)")) {
                    Task { await setAvailable(false, entry: entry, agent: agent) }
                }
                .disabled(!canChange || profile == nil)
                .padding(.trailing, FormMetrics.rowInset)
                .accessibilityIdentifier("knowledge-take-\(entry.path)")
            }
        }
    }

    private func confirmation(_ entry: KnowledgeEntry) -> some View {
        let users = users(of: entry).map(\.agent.agentLabel)
        return HStack(spacing: 8) {
            Text(users.isEmpty ? "Delete “\(entry.title)”?" :
                    "Delete “\(entry.title)”? Founderizer first removes it from the profile of \(users.joined(separator: ", ")).")
                .font(FormMetrics.detail).foregroundStyle(FleetStyle.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Cancel") { deleting = nil }.buttonStyle(FleetOutlineButtonStyle())
            Button("Delete", role: .destructive) { Task { await delete(entry) } }.buttonStyle(FleetDangerButtonStyle())
                .disabled(!canChange).accessibilityIdentifier("knowledge-delete")
        }
    }

    /// An http or https address with a host, or nil.
    private static func pageAddress(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.isEmpty == false else { return nil }
        return trimmed
    }

    // MARK: reader

    /// One file, in place of the list, with Back, and its pencil: the text in the app's text box (`editor`).
    private func reader(_ entry: KnowledgeEntry) -> some View {
        FleetPage(entry.title, back: FleetBack("Knowledge") { opened = nil }) {
            Group {
                if let draft, draft.path == entry.path {
                    editor(entry)
                } else if let file, file.path == entry.path {
                    let cut = file.text.count > Self.readerLimit
                    // **A form page's card** (margins row 17): the form's 680 points from the page's left edge and the
                    // rows' 16 inside, as every card of Settings. It took the column's whole 1,100, a line too long to
                    // read, with 18 inside.
                    // **Only two rows of the file can be selected at a time** (a block, or a cell of a table;
                    // `MessageText.selection`), and a block or a cell of more than 2,000 bytes always: a long file had
                    // a hidden text field over each of them, and each field drew again at every frame of the page's
                    // scroll. Equatable: a new reading of the fleet makes the page again, and not the file's blocks.
                    MessageText(text: cut ? String(file.text.prefix(Self.readerLimit)) : file.text,
                                selection: selection)
                        .equatable()
                        .padding(FormMetrics.rowInset).frame(maxWidth: FormMetrics.formWidth, alignment: .leading)
                        .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
                        // The form cards' edge, which Increase Contrast raises to 4:1 (fix round 3c, HIG; T-41).
                        .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius)
                            .strokeBorder(FleetStyle.hairline(0.08), lineWidth: FleetStyle.edgeWidth(contrast)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if cut {
                        Text("The first \(Self.readerLimit.formatted()) characters show. The agents read the whole file.")
                            .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                    }
                } else if fileError != nil || store.connectionError != nil {
                    // While the hub does not answer nothing is read: the failed row, never "Reading the file…". **Not
                    // while the window's notice says the outage** (`FleetStore.hubNoticeShows`; fix round 3, item 33):
                    // it is said once, over the page.
                    if !store.hubNoticeShows {
                        FormSection {
                            FormRow("Founderizer cannot read this file now.", detail: fileError)
                                .help(behind(fileError)).accessibilityValue(behind(fileError))
                        }
                    }
                } else {
                    LoadingLine(String(l10n: "Reading the file…"))
                }
            }
        } actions: { readerActions(entry) }
        .scrollsAsAChat(selection, store: store)
        .task(id: entry.path) {
            readerShows = entry.path
            readerReading = entry.path
            if let fresh = await read(entry) {
                giveBack(entry.path, fresh: fresh)
                if readerReading == entry.path { readerReading = nil }
            }
        }
        // Back, Esc or another page: what was typed and not saved yet goes with it.
        .onDisappear { readerShows = nil; leave() }
    }

    /// The pencil while the page shows the formatted text, of a file whose text the hub changes in place; the save
    /// mark and the check mark while the box shows.
    @ViewBuilder private func readerActions(_ entry: KnowledgeEntry) -> some View {
        if draft?.path == entry.path {
            SaveMark(state: saveState) { save(draft) }
            IconButton(symbol: "checkmark", words: String(l10n: "Done")) { done() }.accessibilityIdentifier("knowledge-done")
        } else if entry.isOwner, store.state?.ui_features?.contains(KnowledgeClient.editFeature) == true,
                  let file, file.path == entry.path, let edit = KnowledgeEdit(file: file) {
            IconButton(symbol: "pencil", words: String(l10n: "Edit \(entry.title)")) {
                guard !saving(edit.path), !waitsForRead(edit.path) else { return }
                // Words of his that wait for this file come back first, on the text that its reader read: a leave's
                // read in a page that went away can end after this page's read (round 7).
                if Self.heldDrafts[heldDraftKey(edit.path)] != nil, readerReading != edit.path {
                    giveBack(edit.path, fresh: file)
                    if draft != nil { return }
                }
                saveState = nil; problem = nil; keptKeys = []; asked = []; home = currentHome
                taken[edit.path] = edit.saved; draft = edit
            }
            .disabled(!canChange || saving(entry.path) || waitsForRead(entry.path))
            .accessibilityIdentifier("knowledge-edit")
        }
    }

    /// **The file's text in the app's text box** (UI-PATTERNS, "Edit one long text": the text fills the page in a
    /// form's card): the text after the file's title and Source lines, which the hub keeps. **It takes the page's height
    /// under the title, and the page stays a form page**, so the header keeps the cards' 680 points and the check mark
    /// stands where the pencil stood (the owner, 5 November 2026: the top buttons end where the cards end). A page that
    /// `fills` keeps the column's 1,100 for its header.
    ///
    /// **A key in it waits for his choice, as in the chat's composer** (`KeyHoldBanner`, under the box): one that he
    /// pastes is not pasted, and words that add one to the file are not saved, until he saves it as a secret or keeps
    /// it; a key-like part that the file held already asks nothing (`addedKey`). Until 22 November 2026 the box saved
    /// such words into the file, which agents read.
    private func editor(_ entry: KnowledgeEntry) -> some View {
        let box = keyBox(entry.path)
        return VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: Binding(get: { draft?.text ?? "" }, set: { draft?.text = $0 }))
                .font(FormMetrics.text)
                // The words where they stood: the box's own 7 points of room come out of the row's inset.
                .padding(.horizontal, FormMetrics.rowInset - 5 - 7).padding(.vertical, 10 - 7)
                .frame(maxWidth: .infinity)
                .fleetTextBox(focus: $typing)
                .containerRelativeFrame(.vertical) { height, _ in max(Self.editorLeast, height - Self.editorRoom - keyStrip) }
                .onAppear { typing = true }
                .accessibilityLabel("Text of \(entry.title)").accessibilityIdentifier("knowledge-text")
            if let held = store.heldKey, held.composer == box {
                let reader = keyReader(entry)
                KeyHoldBanner(hold: held.hold, agent: reader, holds: .file) { saveHeldKey(held, reader: reader) } goOn: {
                    keepHeldKey(held)
                }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { keyStrip = $0 + 10 }
                    .onDisappear { keyStrip = 0 }
            }
            if let problem {
                Text(problem).font(FormMetrics.detail).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("knowledge-problem")
                    .help(behind(problem)).accessibilityValue(behind(problem))
            }
        }
        .animation(SaveState.lineMotion, value: problem)
        .frame(maxWidth: FormMetrics.formWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: typing) { was, now in if was && !now { save(draft) } }
        .task(id: draft?.text) { await heldKeyCheck() }
        .keyPasteGuard(store: store, composer: typing && SecretEntryView.isOffered(by: store) ? box : nil)
        // The question of a key goes with the box, so no other box waits behind it.
        .onDisappear { if store.heldKey?.composer == box { store.heldKey = nil } }
    }

    /// The box's name in the guard of a key (`HeldKey`): its file, in its hub's database.
    private func keyBox(_ path: String) -> String { "knowledge:\(store.state?.db ?? ""):\(path)" }

    /// The agent that gets the secret's name after "Save it as a secret" (the question names none: the file's words are
    /// every reader's): the first agent of the fleet that reads the file, else the manager, who gives files to agents.
    private func keyReader(_ entry: KnowledgeEntry) -> String {
        let readers = Set(users(of: entry).map(\.agent))
        return store.state?.agents.map(\.name).first { readers.contains($0) } ?? store.state?.managerName ?? "manager"
    }

    /// The edit against the text that the hub took last for its file (`taken`), as a save compares them.
    private func hubText(_ edit: KnowledgeEdit) -> KnowledgeEdit {
        var edit = edit
        if let text = taken[edit.path] { edit.saved = text }
        return edit
    }

    /// **The key-like parts of the edit's text that the hub's text does not hold**, in the order of the text, and the
    /// hub's text's parts as read. They are `KeyInText.all`'s parts, compared as a set, as the hub compares a change in
    /// place (`knowledge_key`): the box asks where the hub would refuse. **Both texts are read in the form that the hub
    /// saves** (`KeyInText.savedForm`: its line ends and control characters; round 8), so a kept part is the hub's
    /// part, and a key that only the saved file sets apart asks; the box shows and keeps his own words. A file that
    /// holds such a part already is not held for it, and an edit that changes nothing reads nothing. Off the main
    /// actor: the rule reads a long file in seconds.
    nonisolated private static func added(_ edit: KnowledgeEdit, savedKeys: Set<String>?) -> (keys: [Substring], savedKeys: Set<String>?) {
        guard edit.isChanged else { return ([], savedKeys) }
        let keys = savedKeys ?? Set(KeyInText.all(in: KeyInText.savedForm(edit.saved)).map(String.init))
        return (KeyInText.all(in: KeyInText.savedForm(edit.text)).filter { !keys.contains(String($0)) }, keys)
    }

    /// **The place in his words of a part of their saved form** (`added`), or nil: the saved form changes his words one
    /// character for one, but for "\r\n", which it makes one "\n". "Save it as a secret" takes the key out of his
    /// own words there.
    nonisolated private static func wordsRange(of part: Substring, in words: String) -> Range<String.Index>? {
        let saved = part.base
        // the same scalars, not only the same characters: the places below count scalars (round 9)
        guard saved.unicodeScalars.elementsEqual(KeyInText.savedForm(words).unicodeScalars) else { return nil }
        // where each character of the saved form comes from in his words, and where his words end
        var places: [String.Index] = [], index = words.unicodeScalars.startIndex, afterReturn = false
        while index < words.unicodeScalars.endIndex {
            let value = words.unicodeScalars[index].value
            if afterReturn, value == 0x0A {
                afterReturn = false
            } else {
                afterReturn = value == 0x0D
                places.append(index)
            }
            index = words.unicodeScalars.index(after: index)
        }
        places.append(words.unicodeScalars.endIndex)
        let start = saved.unicodeScalars.distance(from: saved.unicodeScalars.startIndex, to: part.startIndex)
        let end = start + part.unicodeScalars.count
        guard end < places.count else { return nil }
        return places[start]..<places[end]
    }

    /// The parts that the box's words add to the hub's text (`added`), as read already for these words on that text,
    /// or nil when they were not read yet: no read on the main thread. None where the hub has no secrets, where no box
    /// holds a key.
    private func knownKeys(_ edit: KnowledgeEdit) -> [Substring]? {
        guard SecretEntryView.isOffered(by: store) else { return [] }
        let edit = hubText(edit)
        guard let checked, checked.text == edit.text, checked.saved == edit.saved else { return nil }
        return checked.keys
    }

    /// The parts that the box's words add: as read already, else read now off the main thread (`checked` keeps them).
    private func addedKeys(_ edit: KnowledgeEdit) async -> [Substring] {
        if let known = knownKeys(edit) { return known }
        let edit = hubText(edit), cached = savedKeys?.text == edit.saved ? savedKeys?.keys : nil, pause = Self.readPause
        let reading = await Task.detached(priority: .userInitiated) {
            pause?()
            return Self.added(edit, savedKeys: cached)
        }.value
        if cached == nil, let keys = reading.savedKeys { savedKeys = (edit.saved, keys) }
        checked = (edit.text, edit.saved, reading.keys)
        return reading.keys
    }

    /// The words add a part that he did not keep: the box asks before they go.
    private func holds(_ keys: [Substring]) -> Bool { keys.contains { !keptKeys.contains(String($0)) } }

    /// The strip asks, under the box of this file, about these parts that he did not keep (`asked`). **While it asks
    /// already, what it asks about stays**: a part that came in after the strip came up, and that a save read
    /// meanwhile, asks in a new strip after his choice, and "Keep it" never covers it unseen (round 3).
    private func ask(_ path: String, _ keys: [Substring]) {
        let mine = HeldKey(composer: keyBox(path), hold: .text)
        if store.heldKey != mine { asked = Set(keys.map(String.init).filter { !keptKeys.contains($0) }) }
        store.heldKey = mine
    }

    /// Words of his wait for this file, and its reader has not read it yet (`readerReading`).
    private func waitsForRead(_ path: String) -> Bool {
        readerReading == path && Self.heldDrafts[heldDraftKey(path)] != nil
    }

    /// A save of this file is on its way (`onTheWay`).
    private func saving(_ path: String) -> Bool {
        _ = saveEnded
        return Self.onTheWay[heldDraftKey(path)] != nil
    }

    /// Words that add a key, however they came in, get the question once; words that add none end it. The box's words
    /// are read after a pause in his typing and off the main thread, unlike a composer's: a file holds up to a
    /// megabyte, and the guard can take seconds for one, which at each key would hold his typing.
    private func heldKeyCheck() async {
        guard SecretEntryView.isOffered(by: store), let edit = draft else { return }
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        let keys = await addedKeys(edit)
        guard !Task.isCancelled, draft?.path == edit.path, draft?.text == edit.text else { return }
        let mine = HeldKey(composer: keyBox(edit.path), hold: .text)
        if !holds(keys) {
            if store.heldKey == mine { store.heldKey = nil }
        } else if store.heldKey == nil {
            ask(edit.path, keys)
        }
    }

    /// "Save it as a secret": the key goes into the secure form over the page and out of the box's text, and the agent
    /// of `keyReader` gets the secret's name in its chat where he has one. Only the key leaves the text: the
    /// file's other lines and spaces stay as they are, and so does a key-like part that the file held already. A paste
    /// reads the clipboard again now.
    private func saveHeldKey(_ held: HeldKey, reader: String) {
        store.heldKey = nil
        let tell = store.canChat(with: reader) ? reader : nil
        guard held.hold == .text, let edit = draft else {
            // a paste: the text that the guard checked at Cmd+V
            store.secretForm = SecretPreset(tell: tell, key: held.checked.flatMap { KeyCut.split($0)?.key },
                                            kept: SecretValueKept())
            return
        }
        Task {
            var cut: String?
            // the first part that he did not keep, cut from the very text that was read, while the box still holds it
            if let key = await addedKeys(edit).first(where: { !keptKeys.contains(String($0)) }),
               draft?.path == edit.path, draft?.text == edit.text, let place = Self.wordsRange(of: key, in: edit.text) {
                // the secret is the key as the box held it, its line ends included (round 9)
                var text = edit.text
                cut = String(text[place])
                text.removeSubrange(place)
                draft?.text = text
            }
            store.secretForm = SecretPreset(tell: tell, key: cut, kept: SecretValueKept())
        }
    }

    /// "Paste it anyway": the paste of the text that the guard checked at Cmd+V (`paste`), just after the press. "Keep
    /// it": the box's text is saved now, as the save that the question held. Each keeps the key-like parts that its
    /// question was about, and only those (`keptKeys`): the parts of the checked text, or the parts that the strip's
    /// check found (`asked`).
    private func keepHeldKey(_ held: HeldKey) {
        store.heldKey = nil
        if held.hold == .paste {
            guard held.checked != nil, let edit = draft, held.composer == keyBox(edit.path) else { return }
            // Not in the button's action: there, the text view's insert changed nothing (the probe of 26 November
            // 2026), so "Paste it anyway" pasted nothing.
            Task { @MainActor in paste(held, into: edit.path) }
        } else if let edit = draft {
            keptKeys.formUnion(asked)
            asked = []
            queue(edit, .save)
        }
    }

    /// **The paste of "Paste it anyway"**, as Cmd+V would have made it: the text that the guard checked at Cmd+V, not the
    /// clipboard of now, at the cursor of the box's own text view, which had the cursor at Cmd+V (`KeyCut.target`):
    /// never into another field that has the cursor meanwhile, and nothing when the box is gone. The box's words then
    /// hold the pasted text, also when the text view took no insert. A text view whose text is not the box's words is
    /// not the box (a field that took the cursor just before Cmd+V, a search field, a stale view): nothing goes
    /// anywhere then, and the box's words never take that view's text.
    private func paste(_ held: HeldKey, into path: String) {
        guard let pasted = held.checked, let edit = draft, edit.path == path, let view = KeyCut.target,
              view.window != nil, view.isEditable, view.string == edit.text
        else { return }
        let place = view.selectedRange(), words = view.string as NSString
        guard NSMaxRange(place) <= words.length else { return }
        let text = words.replacingCharacters(in: place, with: pasted)
        // the parts of the saved form, at most 100,000 characters
        keptKeys.formUnion(KeyInText.all(in: KeyInText.savedForm(pasted)).map(String.init))
        view.insertText(pasted, replacementRange: place)
        // only over the very words that the paste read: the text view's own insert changed them already
        if draft?.path == path, draft?.text == edit.text { draft?.text = text }
    }

    /// The page's height that is not the box's: its top and bottom margins, the header and the space under it.
    private static let editorRoom: CGFloat = FleetSpace.top + 36 + FleetSpace.block + FleetSpace.bottom
    /// The least height of the box, in the smallest window.
    private static let editorLeast: CGFloat = 240

    /// The check mark: the box's text goes to the hub, and the page shows the formatted text again. Words that add a
    /// key that he did not keep keep the box open, with the question under it. Words that were read already close the
    /// box at once; others close it once they are read (`settle`).
    private func done() {
        guard let edit = draft else { return }
        if let known = knownKeys(edit), !holds(known) { draft = nil; typing = false }
        queue(edit, .close)
    }

    /// The page goes away: what the box holds goes to the hub, and the next file opens with its formatted text. Words
    /// that add a key that he did not keep are not saved: they wait in memory, and the file gives them back with the
    /// question when it opens again (`heldDrafts`): at once for words that were read already, else once they are read.
    private func leave() {
        guard let edit = draft else { return }
        draft = nil
        if let known = knownKeys(edit), holds(known) {
            Self.heldDrafts[heldDraftKey(edit.path, at: home)] = HeldText(edit: hubText(edit), after: Self.saves)
            return
        }
        queue(edit, .leave)
    }

    /// The file's name among the texts that a key held (`heldDrafts`): its hub, its generation and its path.
    private func heldDraftKey(_ path: String, at home: KnowledgeHome? = nil) -> String {
        "\((home?.hub ?? store.hub).absoluteString) \(home?.db ?? store.state?.db ?? "") \(path)"
    }

    /// The hub and the generation that the app reads now, or nil before its first reading.
    private var currentHome: KnowledgeHome? {
        guard let db = store.state?.db else { return nil }
        return KnowledgeHome(hub: store.hub, db: db, keyCheck: store.state?.checksKnowledgeKeys == true)
    }

    /// **The file opens in the box with his text that a key held when the page went away**, and the box asks again:
    /// only after the hub's text has been read again, and only while that text is the one that his edit began from.
    /// A text that the hub has changed meanwhile (an agent's edit, another save, a file that went and came back) drops
    /// it, because its save sends the whole text and would put his old one over the newer one; so does a hub's text that
    /// is his text already. While the hub gives no text, it waits.
    private func giveBack(_ path: String, fresh file: KnowledgeFile) {
        dropGoneDrafts()
        let key = heldDraftKey(path)
        guard draft == nil, let held = Self.heldDrafts[key] else { return }
        Self.heldDrafts[key] = nil
        var kept = held.edit
        // The hub's text is in its saved form, and the text that a save of this Mac left (`taken`) is his own words:
        // they are the same text when their saved forms are, each trimmed alike (round 9: "\r\n" or U+0001 in a
        // saved text dropped his held words on his return; round 10: the hub strips the saved form, so a control
        // character at an end became a space and went).
        let same = { (text: String) in KeyInText.savedForm(text).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let fresh = KnowledgeEdit(file: file), fresh.path == kept.path,
              held.anyBase || same(fresh.saved) == same(kept.saved)
        else { return }
        kept.saved = fresh.saved
        guard kept.isChanged else { return }
        // the text read now is the one that the box compares with, also for words whose text was not known (round 4)
        taken[path] = fresh.saved
        saveState = nil; problem = nil; keptKeys = []; asked = []; home = currentHome; draft = kept
    }

    /// The texts that a key held and that no file will give back go: those of another hub or another generation of
    /// it, and those whose file the hub lists no more, so no key stays in memory longer than it can be used.
    private func dropGoneDrafts() {
        guard store.state != nil else { return }
        let here = heldDraftKey(""), listed = store.state?.knowledge.map { Set($0.map { heldDraftKey($0.path) }) }
        let keeps = { (key: String) in key.hasPrefix(here) && listed?.contains(key) != false }
        if Self.heldDrafts.keys.contains(where: { !keeps($0) }) { Self.heldDrafts = Self.heldDrafts.filter { keeps($0.key) } }
    }

    /// One save of the box's text, after the save before it. Nothing goes when the text is what the hub has, or while
    /// it adds a key that he did not choose to keep (`settle`).
    private func save(_ edit: KnowledgeEdit?) {
        guard let edit else { return }
        queue(edit, .save)
    }

    /// What a save of the box does with words that add a key that he did not keep (`settle`).
    private enum SaveWay {
        /// The cursor left the box, or the save mark: the question shows under the box.
        case save
        /// The check mark: the box closes once the words are read, or stays with the question.
        case close
        /// The page went away: the words wait in memory for the file (`heldDrafts`).
        case leave
    }

    /// The saves of the box that were queued on this Mac, by number: a held text moves on only with the saves that
    /// were on their way when it was held (`HeldText.after`).
    @MainActor private static var saves = 0

    /// **One save of the box's words, after the save before it**, in the order of his presses. The words are read
    /// first, off the main thread and with no wait for the hub (`addedKeys`, `settle`), so the question or the closed
    /// box comes at once; then the save waits for the one before it. Nothing goes while the words add a key that he
    /// did not keep.
    private func queue(_ edit: KnowledgeEdit, _ way: SaveWay) {
        guard let home = home ?? currentHome else { return }
        let before = sending, saved = heldDraftKey(edit.path, at: home)
        Self.saves += 1
        let number = Self.saves
        Self.onTheWay[saved, default: 0] += 1
        sending = Task {
            let kept = settle(edit, adding: await addedKeys(edit), way: way, number: number, home: home)
            await before?.value
            if let kept { await send(edit, kept: kept, number: number, home: home) }
            Self.onTheWay[saved, default: 1] -= 1
            if Self.onTheWay[saved] == 0 { Self.onTheWay[saved] = nil }
            saveEnded += 1
        }
    }

    /// The words of a save, once read: nil while they add a part that he did not keep, which the box asks about, or
    /// which waits in memory for the file when the page went away; else the parts that they add, every one of which he
    /// kept, which their save names to the hub (`key_kept`).
    private func settle(_ edit: KnowledgeEdit, adding keys: [Substring], way: SaveWay, number: Int,
                        home: KnowledgeHome) -> [String]? {
        guard !holds(keys) else {
            if way == .leave {
                // On the text that this Mac saved or read last now: a save that landed during this read moved it, and a
                // held text on the text before it was dropped on his return as one that the hub had changed (round 2).
                Self.heldDrafts[heldDraftKey(edit.path, at: home)] = HeldText(edit: hubText(edit), after: number - 1)
                // He may have opened the file again while this read ran, and its reader's read ended first and found
                // nothing to give back: the words come back now, on the text that it read (round 7).
                if readerShows == edit.path, readerReading != edit.path, let file, file.path == edit.path {
                    giveBack(edit.path, fresh: file)
                }
            } else if draft?.path == edit.path, draft?.text == edit.text {
                // (a read of words that the box no longer holds asks nothing: the box's own check reads its words)
                ask(edit.path, keys)
            }
            return nil
        }
        if way == .close, draft?.path == edit.path, draft?.text == edit.text { draft = nil; typing = false }
        return keys.map(String.init)
    }

    private func send(_ edit: KnowledgeEdit, kept: [String], number: Int, home: KnowledgeHome) async {
        // The text the hub took last for this file, which a save before this one may have moved on.
        let edit = hubText(edit)
        if edit.sent.isEmpty {
            saveState = .failed(KnowledgeEdit.empty); problem = KnowledgeEdit.empty
            if draft?.path != edit.path { message = (KnowledgeEdit.empty, true) }
            return
        }
        guard edit.isChanged else { return }
        // The hub takes at most 1 MiB of a file's text: a longer text is refused here, in the words of Add file, which
        // stay true (a file of 1.0 to 1.048 MB that another route made can still be edited).
        if edit.sent.utf8.count > KnowledgeClient.hubTextLimit {
            let large = KnowledgeImport.ImportError.large.localizedDescription
            saveState = .failed(large); problem = large
            if draft?.path != edit.path { message = (large, true) }
            return
        }
        // The kept parts that the text that the hub took last holds already need no naming: a save before this one
        // took them.
        var kept = kept
        if !kept.isEmpty {
            let base = edit.saved, cached = savedKeys?.text == base ? savedKeys?.keys : nil
            let held = await Task.detached(priority: .userInitiated) {
                cached ?? Set(KeyInText.all(in: KeyInText.savedForm(base)).map(String.init))
            }.value
            kept.removeAll { held.contains($0) }
        }
        // The box's own hub and generation (`home`); while the app reads that one, a moment with no answer holds the save.
        let here = store.hub == home.hub && store.state?.db == home.db
        guard !here || store.writesNow else {
            saveState = .failed(Self.unanswered); problem = Self.unanswered
            if draft?.path != edit.path { message = (Self.unanswered, true) }
            return
        }
        saveState = .saving; problem = nil
        do {
            // **His "Keep it" goes with the words that he kept, and with no others** (`settle`, `key_kept`): the parts
            // that they add to the text that the hub took last and that he kept, `[]` for none, only where the box's
            // own hub checks a file for a key: as the app reads it now while that is the box's hub, else as it was when
            // the box opened (`home`); an older hub refuses a field that it does not know.
            let keyCheck = here ? store.state?.checksKnowledgeKeys == true : home.keyCheck
            _ = try await client.edit(hub: home.hub, database: home.db, client: store.installation, path: edit.path,
                                      text: edit.sent, keyCheck: keyCheck, kept: kept)
            taken[edit.path] = edit.sent
            if draft?.path == edit.path { draft?.saved = edit.sent }
            // **His text that a key held when the page went away began from the text that this save replaced**: it
            // begins from this save now. It held the old one, so the file dropped it on its return as a text that the
            // hub had changed (`giveBack`), when this save was still on its way as he left (the coordinator's S1).
            // Only a save that was on its way then moves it: a later edit's save is not the base of the held text.
            let held = heldDraftKey(edit.path, at: home)
            if let text = Self.heldDrafts[held] {
                if number <= text.after, text.edit.saved == edit.saved {
                    Self.heldDrafts[held]?.edit.saved = edit.sent
                } else if number > text.after, text.anyBase {
                    // A later save landed over words of his that a refusal held on any text (round 5): they would
                    // come back over it on his return, so they go.
                    Self.heldDrafts[held] = nil
                }
            }
            saveState = .saved
            Task {
                try? await Task.sleep(for: .seconds(2))
                if saveState == .saved { saveState = nil }
            }
            // The formatted text, its size and its "Changed" line, as the hub has them now.
            if here, let entry = store.state?.knowledge?.first(where: { $0.path == edit.path }) { await read(entry) }
            if here { await store.refresh() }
        } catch {
            cause = Self.cause(error)
            let why = Self.reason(error)
            saveState = .failed(why); problem = why
            // A page that went away shows its refusal on the list's line.
            if draft?.path != edit.path { message = (why, true) }
            if case HubError.refusal(let refused) = error, refused.code == KnowledgeClient.keyRefusal {
                await refusedKey(edit, kept: kept, number: number, home: home)
            }
        }
    }

    /// **A save that the hub refused for what looks like a key** (round 2 of 24 November 2026). Another hand may have
    /// changed the file at the hub (a second Mac, the manager's team plan), so the file is read again, and its text
    /// becomes the one that the box compares with: the parts that are new against it ask in the strip, and the parts
    /// that he kept for this save ask again. His words are never lost. While a box is open on the file, whatever its
    /// words (he may have typed on after the save went), those words are checked against that text, and the refused
    /// ones are held nowhere: the box holds his words (round 4). When no box is open on it (the check mark closed it,
    /// or he left), the refused words wait in memory for the file, as words that a key held on leaving
    /// (`heldDrafts`), and come back at once when the page shows that file.
    private func refusedKey(_ edit: KnowledgeEdit, kept: [String], number: Int, home: KnowledgeHome) async {
        keptKeys.subtract(kept)
        var held = HeldText(edit: edit, after: number, anyBase: true)
        var base: String?
        if let fresh = try? await client.file(hub: home.hub, database: home.db, path: edit.path),
           let read = KnowledgeEdit(file: fresh)?.saved {
            base = read
            taken[edit.path] = read
            held.edit.saved = read; held.anyBase = false
            if draft?.path == edit.path { draft?.saved = read }
            if opened == edit.path, store.hub == home.hub, store.state?.db == home.db { file = fresh }
        }
        if let words = draft, words.path == edit.path {
            let keys = await addedKeys(words)
            // (his words changed during the read: the refusal's line does not stand under them, and their own check
            // asks about them)
            guard draft?.path == words.path, draft?.text == words.text else { problem = nil; return }
            if holds(keys) {
                problem = nil
                ask(edit.path, keys)
            } else if words.text != edit.text {
                // the refusal was of words that the box no longer holds: its line does not stand under these
                problem = nil
            }
            return
        }
        let key = heldDraftKey(edit.path, at: home)
        // A later save of the file is on its way (he closed the box with newer words during the read): it carries his
        // newer words, so the refused ones are neither held nor given back (round 5).
        if (Self.onTheWay[key] ?? 0) > 1 { return }
        if let newer = Self.heldDrafts[key], newer.after >= number {
            // A newer text of his that waits already, held after this save was queued (he added a key and left while it
            // was on its way), stays: the refused older words never replace it (round 3, reader 1). It began from the
            // text that this save began from, so it now begins from the text read again, or from any text when that
            // read failed (round 4): else the file dropped it on his return as words on an older text.
            if newer.edit.saved == edit.saved {
                if let base { Self.heldDrafts[key]?.edit.saved = base } else { Self.heldDrafts[key]?.anyBase = true }
            }
        } else {
            Self.heldDrafts[key] = held
        }
        if readerShows == edit.path, let file, file.path == edit.path { giveBack(edit.path, fresh: file) }
    }

    /// The file's text from the hub, kept for the reader; it gives back the text that it read, or nil when it read none.
    @discardableResult private func read(_ entry: KnowledgeEntry) async -> KnowledgeFile? {
        fileError = nil
        guard let db = store.state?.db else { return nil }
        let start = ContinuousClock.now, first = file?.path != entry.path
        do {
            let read = try await client.file(hub: store.hub, database: db, path: entry.path)
            guard !Task.isCancelled else { return nil }
            if first { await store.settle(since: start) }
            file = read
            return read
        } catch {
            guard !Task.isCancelled else { return nil }
            if first { await store.settle(since: start) }
            cause = Self.cause(error); fileError = Self.reason(error)
            return nil
        }
    }

    /// **A file's text is read while the pointer is on its row** (10 November 2026), as a task's thread is
    /// (`FleetStore.prefetchTask`): a file that opened for the first time drew its title alone for the 250 ms of its
    /// read, and then its text and its pencil; the file he read last was whole in its first frame. The pointer is on a
    /// row some tenths of a second before the click, which is the time that the read takes. Not for a pointer that
    /// only passes over the list, and never under a file that shows: its text is kept only while the list shows, or
    /// for the file that he opened meanwhile. A read that fails keeps nothing, and the file reads for itself as before.
    private func readAhead(_ entry: KnowledgeEntry, under pointer: Bool) {
        ahead?.cancel(); ahead = nil
        guard pointer, opened == nil, file?.path != entry.path, store.isFresh, let db = store.state?.db else { return }
        let hub = store.hub
        ahead = Task {
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let read = try? await client.file(hub: hub, database: db, path: entry.path), !Task.isCancelled,
                  store.hub == hub, store.state?.db == db, opened == nil || opened == entry.path else { return }
            file = read
        }
    }

    // MARK: changes

    private func chooseFiles() {
        guard let urls = KnowledgeImport.choose() else { return }
        Task { await add(urls) }
    }

    /// Each file's text, made on this Mac, as one knowledge file. A file that fails does not stop the others. On one
    /// agent's page, that agent reads each new file at once.
    ///
    /// **A file that holds what looks like a key is not sent** (`KnowledgeImport.file`), and its line in the status
    /// line says so in the strip's own words; the other files of the same add go on. Agents read knowledge files on
    /// their own machines, and until 24 November 2026 Add file and a drop sent a file's whole text with no look (the
    /// coordinator's M1). This is the stop-gap until his yes to the strip on this list: an honest look-alike (an id, a
    /// hash) still goes in through the file's text box, where the strip asks and "Keep it" saves it.
    private func add(_ urls: [URL]) async {
        guard canChange, let db = store.state?.db else { return }
        let hub = store.hub, installation = store.installation, keyCheck = store.state?.checksKnowledgeKeys == true
        var added: [String] = [], refused: [String] = []
        message = nil
        for (index, url) in urls.enumerated() {
            let name = url.lastPathComponent
            busy = urls.count == 1 ? String(l10n: "Adding \(name)…") : String(l10n: "Adding \(index + 1) of \(urls.count): \(name)…")
            do {
                let file = try await KnowledgeImport.file(of: url)
                _ = try await client.add(hub: hub, database: db, client: installation, title: file.title,
                                         text: file.text, source: file.source, keyCheck: keyCheck)
                added.append(name)
            } catch { cause = Self.cause(error) ?? cause; refused.append("\(name): \(Self.reason(error))") }
        }
        busy = nil
        let done = added.isEmpty ? [] : [String(l10n: "Added \(added.joined(separator: ", ")).")]
        message = ((done + refused).joined(separator: " "), !refused.isEmpty)
        await readProfiles()
        await store.refresh()
    }

    private func addPage() async {
        guard canChange, let url = Self.pageAddress(address), let db = store.state?.db else { return }
        let hub = store.hub, installation = store.installation, keyCheck = store.state?.checksKnowledgeKeys == true
        await run(String(l10n: "The hub reads \(url)…")) {
            let receipt = try await client.addPage(hub: hub, database: db, client: installation, url: url, keyCheck: keyCheck)
            address = ""; addingURL = false
            return String(l10n: "Added “\(receipt.title ?? receipt.path)”.")
        }
    }

    private func setAvailable(_ on: Bool, entry: KnowledgeEntry, agent: String) async {
        guard canChange, let profile = profiles?.first(where: { $0.agent == agent }), let db = store.state?.db else { return }
        let hub = store.hub, installation = store.installation
        await run(on ? String(l10n: "Adding “\(entry.title)” to the profile of \(agent.agentLabel)…") : String(l10n: "Removing “\(entry.title)” from the profile of \(agent.agentLabel)…")) {
            try await client.setAvailable(on, path: entry.path, profile: profile, hub: hub, database: db, client: installation)
            return on ? String(l10n: "\(agent.agentLabel) now reads “\(entry.title)”.") : String(l10n: "\(agent.agentLabel) no longer reads “\(entry.title)”.")
        }
    }

    /// Removes the file from every profile that lists it, then deletes it: the hub refuses to delete a listed file.
    private func delete(_ entry: KnowledgeEntry) async {
        guard canChange, let db = store.state?.db else { return }
        let hub = store.hub, installation = store.installation, users = users(of: entry)
        deleting = nil
        await run(String(l10n: "Deleting “\(entry.title)”…")) {
            for profile in users {
                try await client.setAvailable(false, path: entry.path, profile: profile, hub: hub, database: db, client: installation)
            }
            _ = try await client.delete(hub: hub, database: db, client: installation, path: entry.path)
            if opened == entry.path { opened = nil }
            if carded?.id == entry.path { carded = nil }
            return String(l10n: "Deleted “\(entry.title)”.")
        }
    }

    /// One change at the hub: `busy` shows its words meanwhile. Then the profiles and the state are read again.
    private func run(_ words: String, _ work: () async throws -> String) async {
        busy = words; message = nil
        do { message = (try await work(), false) } catch { cause = Self.cause(error); message = (Self.reason(error), true) }
        busy = nil
        await readProfiles()
        await store.refresh()
    }

    private func users(of entry: KnowledgeEntry) -> [AgentProfile] {
        (profiles ?? []).filter { KnowledgeAccess.paths($0.sections)?.contains(entry.path) == true }
    }

    private static func reason(_ error: Error) -> String {
        if case HubError.refusal(let refused) = error {
            // A hub's refusal of what looks like a key (`knowledge_key`), in the strip's own sentence and the owner's
            // language. The code moves to `RefusalMeaning` once the hub's table of codes has it.
            if refused.code == KnowledgeClient.keyRefusal { return String(l10n: "This file holds what looks like a key.") }
            let text = refused.words
            return String(l10n: "Not done. The hub said: \(text.hasSuffix(".") ? text : text + ".")")
        }
        if error is URLError { return unanswered }
        return error.localizedDescription
    }

    /// A change or a read that the hub did not answer, in our words: the system's own are `cause`, on hover.
    private static let unanswered = "The hub did not answer. The change can still arrive: look at the list before you try again."
    private static func cause(_ error: Error) -> String? { error is URLError ? error.localizedDescription : nil }
    /// What stands behind a line: the system's words of an unanswered request, and nothing behind any other line.
    private func behind(_ line: String?) -> String { line?.contains(Self.unanswered) == true ? cause ?? "" : "" }

    // MARK: reading

    /// Reads the profiles every 15 seconds while the page shows, and again after 3 seconds when a read failed.
    private func poll() async {
        opened = nil; deleting = nil; carded = nil
        // The text that the eye of a file's card on an agent's Can use asked for (`readText`), or a press of the file's
        // badge in a request's words (`FleetStore.openCardLink`).
        if agent == nil, let path = store.knowledgeRead { store.knowledgeRead = nil; opened = path }
        let start = ContinuousClock.now
        while !Task.isCancelled {
            dropGoneDrafts()
            let current = await readProfiles(since: start)
            do { try await store.nap(current ? 15 : 3) } catch { return }
        }
    }

    @discardableResult private func readProfiles(since start: ContinuousClock.Instant? = nil) async -> Bool {
        guard store.isFresh, store.state?.ui_features?.contains("profiles") == true, let db = store.state?.db else { return false }
        let hub = store.hub, first = profiles == nil, request = store.pageReadStart()
        let profiles = try? await store.read(Self.profilesName, from: request) {
            try await HubClient().profiles(hub: hub, database: db).profiles
        }
        if first, let start { await store.settle(since: start) }
        guard !Task.isCancelled, let profiles else { return false }
        return store.keep(profiles, as: Self.profilesName, from: request)
    }
}

/// A file's text, made on this Mac: text files as they are, a PDF with PDFKit, and Word, RTF and HTML with
/// NSAttributedString. The hub keeps the text, never the file.
@MainActor enum KnowledgeImport {
    static let types: [UTType] = [.plainText, .pdf, .rtf, .html, UTType("org.openxmlformats.wordprocessingml.document")].compactMap { $0 }

    /// **The files that Add file adds**: the Mac's open panel, or nil when he cancels it. A test gives its own files.
    static var choose: @MainActor () -> [URL]? = {
        let panel = NSOpenPanel()
        panel.title = String(l10n: "Add files to your knowledge")
        panel.prompt = String(l10n: "Add")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = KnowledgeImport.types
        return panel.runModal() == .OK ? panel.urls : nil
    }

    /// The title and the source of a file: its name without and with the extension, in the hub's limits.
    static func title(of url: URL) -> String { String(url.deletingPathExtension().lastPathComponent.prefix(120)) }
    static func source(of url: URL) -> String { String(url.lastPathComponent.prefix(200)) }

    /// **What Add file and a drop send for one file, or why they send nothing for it**: its title, its text and its
    /// source. A file whose text, title or source holds what looks like a key is refused (`ImportError.key`), by the
    /// rule of the box's guard and of the chat's composer (`KeyInText`), read off the main thread: a file's text holds
    /// up to a megabyte. As the hub reads them: the title and the source as they are, the text in the form that it
    /// saves (`KeyInText.savedForm`; round 8).
    static func file(of url: URL) async throws -> (title: String, text: String, source: String) {
        let text = try Self.text(of: url), title = Self.title(of: url), source = Self.source(of: url)
        let holdsKey = await Task.detached(priority: .userInitiated) {
            KeyInText.contains(title) || KeyInText.contains(source) || KeyInText.contains(KeyInText.savedForm(text))
        }.value
        if holdsKey { throw ImportError.key }
        return (title, text, source)
    }

    static func text(of url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let text: String
        if type.conforms(to: .pdf) {
            guard let document = PDFDocument(url: url) else { throw ImportError.unreadable }
            text = document.string ?? ""
        } else if let kind = documentType(type) {
            text = try NSAttributedString(url: url, options: [.documentType: kind], documentAttributes: nil).string
        } else if type.conforms(to: .plainText) {
            let data = try Data(contentsOf: url)
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        } else {
            throw ImportError.kind
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.empty }
        guard trimmed.utf8.count <= KnowledgeClient.textLimit else { throw ImportError.large }
        return trimmed
    }

    private static func documentType(_ type: UTType) -> NSAttributedString.DocumentType? {
        if type.conforms(to: .html) { return .html }
        if type.conforms(to: .rtf) { return .rtf }
        if let word = UTType("org.openxmlformats.wordprocessingml.document"), type.conforms(to: word) { return .officeOpenXML }
        return nil
    }

    enum ImportError: LocalizedError {
        case kind, unreadable, empty, large, key
        var errorDescription: String? {
            switch self {
            case .kind: String(l10n: "Founderizer cannot read this kind of file. Use Markdown, text, PDF, Word (.docx), RTF or HTML.")
            case .unreadable: String(l10n: "Founderizer cannot open this PDF.")
            case .empty: String(l10n: "The file has no text. A scanned PDF can have only pictures.")
            case .large: String(l10n: "The text is larger than 1 MB.")
            case .key: String(l10n: "This file holds what looks like a key.")
            }
        }
    }
}
