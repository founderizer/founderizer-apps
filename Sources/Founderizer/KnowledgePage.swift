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
/// files" section of that agent's profile. Internal knowledge files stay internal: the state has only the owner's.
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
    /// The agents' profiles, for the chips. nil: not read yet. The store's (`FleetStore.reading`), the fleet's page's and
    /// each agent's under its own name, so the page he saw last shows in its first frame when he comes back.
    private var profiles: [AgentProfile]? {
        get { store.reading("knowledge.profiles.\(scope)") } nonmutating set { store.keep(newValue, as: "knowledge.profiles.\(scope)") }
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
    private let client = KnowledgeClient()
    /// The most text that the reader shows: the Markdown view makes every block at once.
    private static let readerLimit = 100_000
    /// The profiles, read before the page first opens (`PagePrefetch`): the fleet's page's, and each agent's.
    static let prefetch = PagePrefetch("knowledge.profiles.fleet", feature: "profiles") {
        try await HubClient().profiles(hub: $0, database: $1).profiles
    }
    static let agentPrefetch = PagePrefetch(agent: { "knowledge.profiles.\($0)" }, feature: "profiles") { hub, database, _ in
        try await HubClient().profiles(hub: hub, database: database).profiles
    }

    private var scope: String { agent ?? "fleet" }
    private var offered: Bool { store.state?.ui_features?.contains(KnowledgeClient.feature) == true }
    private var canChange: Bool { offered && store.isFresh && busy == nil }
    /// The agent's profile, on one agent's page; nil until it is read.
    private var profile: AgentProfile? { agent.flatMap { name in profiles?.first { $0.agent == name } } }
    /// The files the agent of this page reads, by path.
    private var mine: Set<String> { Set(profile.flatMap { KnowledgeAccess.paths($0.sections) } ?? []) }

    var body: some View {
        let entries = store.state?.knowledge
        Group {
            if let entry = entries?.first(where: { $0.path == opened }) { reader(entry) } else { list(entries) }
        }
        .task(id: "\(store.hub)/\(store.state?.db ?? "")") { await poll() }
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
        if let agent, profile != nil, store.isFresh, !open.isEmpty {
            let words = String(l10n: "Give \(agent.agentLabel) a file")
            FleetSelect(words, options: open.map { FleetOption($0.path, $0.title, mark: .symbol(Self.symbol($0))) }) { path in
                guard let entry = open.first(where: { $0.path == path }) else { return }
                Task { await setAvailable(true, entry: entry, agent: agent) }
            } label: {
                Image(systemName: "plus").font(IconMetrics.symbol(13)).foregroundStyle(FleetStyle.muted)
            }
            .buttonStyle(FleetIconButtonStyle(rest: true))
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
                    MessageText(text: cut ? String(file.text.prefix(Self.readerLimit)) : file.text)
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
        .task(id: entry.path) { await read(entry) }
        // Back, Esc or another page: what was typed and not saved yet goes with it.
        .onDisappear { leave() }
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
                saveState = nil; problem = nil; taken[edit.path] = edit.saved; draft = edit
            }
            .disabled(!canChange)
            .accessibilityIdentifier("knowledge-edit")
        }
    }

    /// **The file's text in the app's text box** (UI-PATTERNS, "Edit one long text": the text fills the page in a
    /// form's card): the text after the file's title and Source lines, which the hub keeps. **It takes the page's height
    /// under the title, and the page stays a form page**, so the header keeps the cards' 680 points and the check mark
    /// stands where the pencil stood (the owner, 5 November 2026: the top buttons end where the cards end). A page that
    /// `fills` keeps the column's 1,100 for its header.
    private func editor(_ entry: KnowledgeEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: Binding(get: { draft?.text ?? "" }, set: { draft?.text = $0 }))
                .font(FormMetrics.text)
                // The words where they stood: the box's own 7 points of room come out of the row's inset.
                .padding(.horizontal, FormMetrics.rowInset - 5 - 7).padding(.vertical, 10 - 7)
                .frame(maxWidth: .infinity)
                .fleetTextBox(focus: $typing)
                .containerRelativeFrame(.vertical) { height, _ in max(Self.editorLeast, height - Self.editorRoom) }
                .onAppear { typing = true }
                .accessibilityLabel("Text of \(entry.title)").accessibilityIdentifier("knowledge-text")
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
    }

    /// The page's height that is not the box's: its top and bottom margins, the header and the space under it.
    private static let editorRoom: CGFloat = FleetSpace.top + 36 + FleetSpace.block + FleetSpace.bottom
    /// The least height of the box, in the smallest window.
    private static let editorLeast: CGFloat = 240

    /// The check mark: the box's text goes to the hub, and the page shows the formatted text again.
    private func done() {
        let edit = draft
        draft = nil; typing = false
        save(edit)
    }

    /// The page goes away: what the box holds goes to the hub, and the next file opens with its formatted text.
    private func leave() {
        guard let edit = draft else { return }
        draft = nil
        save(edit)
    }

    /// One save of the box's text, after the save before it. Nothing goes when the text is what the hub has.
    private func save(_ edit: KnowledgeEdit?) {
        guard let edit else { return }
        let before = sending
        sending = Task {
            await before?.value
            await send(edit)
        }
    }

    private func send(_ edit: KnowledgeEdit) async {
        // The text the hub took last for this file, which a save before this one may have moved on.
        var edit = edit
        if let text = taken[edit.path] { edit.saved = text }
        if edit.sent.isEmpty {
            saveState = .failed(KnowledgeEdit.empty); problem = KnowledgeEdit.empty
            if draft?.path != edit.path { message = (KnowledgeEdit.empty, true) }
            return
        }
        guard edit.isChanged else { return }
        guard store.isFresh, let db = store.state?.db else {
            saveState = .failed(Self.unanswered); problem = Self.unanswered
            if draft?.path != edit.path { message = (Self.unanswered, true) }
            return
        }
        saveState = .saving; problem = nil
        do {
            _ = try await client.edit(hub: store.hub, database: db, client: store.installation, path: edit.path, text: edit.sent)
            taken[edit.path] = edit.sent
            if draft?.path == edit.path { draft?.saved = edit.sent }
            saveState = .saved
            Task {
                try? await Task.sleep(for: .seconds(2))
                if saveState == .saved { saveState = nil }
            }
            // The formatted text, its size and its "Changed" line, as the hub has them now.
            if let entry = store.state?.knowledge?.first(where: { $0.path == edit.path }) { await read(entry) }
            await store.refresh()
        } catch {
            cause = Self.cause(error)
            let why = Self.reason(error)
            saveState = .failed(why); problem = why
            // A page that went away shows its refusal on the list's line.
            if draft?.path != edit.path { message = (why, true) }
        }
    }

    private func read(_ entry: KnowledgeEntry) async {
        fileError = nil
        guard let db = store.state?.db else { return }
        let start = ContinuousClock.now, first = file?.path != entry.path
        do {
            let read = try await client.file(hub: store.hub, database: db, path: entry.path)
            guard !Task.isCancelled else { return }
            if first { await store.settle(since: start) }
            file = read
        } catch {
            guard !Task.isCancelled else { return }
            if first { await store.settle(since: start) }
            cause = Self.cause(error); fileError = Self.reason(error)
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
        let panel = NSOpenPanel()
        panel.title = String(l10n: "Add files to your knowledge")
        panel.prompt = String(l10n: "Add")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = KnowledgeImport.types
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await add(urls) }
    }

    /// Each file's text, made on this Mac, as one knowledge file. A file that fails does not stop the others. On one
    /// agent's page, that agent reads each new file at once.
    private func add(_ urls: [URL]) async {
        guard canChange, let db = store.state?.db else { return }
        let hub = store.hub, installation = store.installation
        var added: [String] = [], refused: [String] = []
        message = nil
        for (index, url) in urls.enumerated() {
            let name = url.lastPathComponent
            busy = urls.count == 1 ? String(l10n: "Adding \(name)…") : String(l10n: "Adding \(index + 1) of \(urls.count): \(name)…")
            do {
                let text = try KnowledgeImport.text(of: url)
                _ = try await client.add(hub: hub, database: db, client: installation, title: KnowledgeImport.title(of: url),
                                         text: text, source: KnowledgeImport.source(of: url))
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
        let hub = store.hub, installation = store.installation
        await run(String(l10n: "The hub reads \(url)…")) {
            let receipt = try await client.addPage(hub: hub, database: db, client: installation, url: url)
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
        if case HubError.refusal(_, let text) = error { return String(l10n: "Not done. The hub said: \(text.hasSuffix(".") ? text : text + ".")") }
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
        // The text that the eye of a file's card on an agent's Can use asked for (`readText`).
        if agent == nil, let path = store.knowledgeRead { store.knowledgeRead = nil; opened = path }
        let start = ContinuousClock.now
        while !Task.isCancelled {
            let current = await readProfiles(since: start)
            do { try await store.nap(current ? 15 : 3) } catch { return }
        }
    }

    @discardableResult private func readProfiles(since start: ContinuousClock.Instant? = nil) async -> Bool {
        guard store.isFresh, store.state?.ui_features?.contains("profiles") == true, let db = store.state?.db else { return false }
        let hub = store.hub, first = profiles == nil
        let list = try? await HubClient().profiles(hub: hub, database: db)
        if first, let start { await store.settle(since: start) }
        guard let list, store.hub == hub, store.state?.db == db else { return false }
        profiles = list.profiles
        return true
    }
}

/// A file's text, made on this Mac: text files as they are, a PDF with PDFKit, and Word, RTF and HTML with
/// NSAttributedString. The hub keeps the text, never the file.
@MainActor private enum KnowledgeImport {
    static let types: [UTType] = [.plainText, .pdf, .rtf, .html, UTType("org.openxmlformats.wordprocessingml.document")].compactMap { $0 }

    /// The title and the source of a file: its name without and with the extension, in the hub's limits.
    static func title(of url: URL) -> String { String(url.deletingPathExtension().lastPathComponent.prefix(120)) }
    static func source(of url: URL) -> String { String(url.lastPathComponent.prefix(200)) }

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
        case kind, unreadable, empty, large
        var errorDescription: String? {
            switch self {
            case .kind: String(l10n: "Founderizer cannot read this kind of file. Use Markdown, text, PDF, Word (.docx), RTF or HTML.")
            case .unreadable: String(l10n: "Founderizer cannot open this PDF.")
            case .empty: String(l10n: "The file has no text. A scanned PDF can have only pictures.")
            case .large: String(l10n: "The text is larger than 1 MB.")
            }
        }
    }
}
