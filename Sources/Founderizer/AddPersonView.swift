import FleetCore
import SwiftUI

/// **Add person, as an agent's setup is: one centered step on a page** (`SetupPage`, `SetupStep`) — a mark, a title
/// that names the step, and only the next action under it. The owner, 28 October 2026, of the pages before these:
/// "it has to be centered like the ai provider login, give importance to every step! review the entire wizard."
///
///   1. **Add person**: their name, and nothing else.
///   2. **What should Mia know about Ana?** The note the agent reads about them, which goes into the agent's prompt in
///      their conversations only. It may stay empty. That it is no place for a secret is a line outside the box, so
///      it stays while he types (the owner, 28 October 2026: "it show be 2 steps: name and then the notes textarea,
///      with the explanation outside, otherwise it is gone as soona s i click").
///   3. **What is Ana to you?** Every role of the hub at once, as cards, each with what the agent is told about such
///      a person, in the hub's own words (`GET /ui/people` `roles`). A click is the way on.
///   4. **Who can Ana talk to?** Each agent as its own mark and name, as the sidebar draws it (the owner, the same day:
///      "here we should see each agent icon, make it more visual!"). One that cannot hold a conversation says why on
///      hover. Opened from one agent's People, the person reaches that agent and this step is left out.
///   5. **Where does Ana write from?** Every place they write from, and the two apps that add one more: the same
///      person writes from WhatsApp and from Discord and is one person. Add person is here.
///   6. **Ana's phone number**, or their Discord user ID: one field, and under it where to find it, which stays while
///      he types. Founderizer makes the chat app's own ID from it, so the owner never types
///      `34600111222@s.whatsapp.net`.
///
/// A button shows only while it can be pressed, and while the hub adds the person the title is its moving words.
/// The hub takes the whole person in one command, with every handle (`POST /ui/people`).
struct AddPersonView: View {
    @Bindable var store: FleetStore
    /// The roles as the hub serves them. The People page opens this wizard only once it has read them.
    let roles: [PeopleSnapshot.Role]
    let existing: Int
    /// The handle of a sender nobody answered, when the wizard was opened from that row. It is already theirs.
    let handle: PersonInput.HandleInput?
    /// The agent whose People opened the wizard: the person reaches it, and step four is left out.
    var agent: String? = nil
    let back: () -> Void
    let added: (Int) -> Void

    private enum Page { case who, note, role, agents, places, handle }

    @State private var page = Page.who
    @State private var input = PersonInput()
    /// The place that page six is asking about.
    @State private var draft = PersonInput.HandleInput()
    @State private var busy = false
    @State private var problem: String?
    @State private var filled = false
    private let client = PeopleClient()

    private var canWrite: Bool { store.isFresh && store.state?.db != nil && !busy }
    /// The agents a person may reach: every configured agent but the fleet's manager, which the hub refuses.
    private var agents: [FleetAgent] { (store.state?.agents ?? []).filter { $0.role != "manager" } }
    /// Who they are, in the titles after the first page.
    private var who: String { People.oneLine(input.name) }
    /// Who reads the note: the agent whose People this is, or every agent they will talk to.
    private var reader: String { agent.map(People.agentWord) ?? "your agents" }

    var body: some View {
        // Back stands at the page's top left, where every setup page has it.
        SetupPage { backLink } step: {
            Group {
                switch page {
                case .who: whoPage
                case .note: notePage
                case .role: rolePage
                case .agents: agentsPage
                case .places: placesPage
                case .handle: handlePage
                }
            }.animation(.easeInOut(duration: 0.18), value: page)
        }
        .foregroundStyle(FleetStyle.text)
        .onAppear(perform: opened)
        .accessibilityIdentifier("add-person")
    }

    /// The name of the page he is on. Each one says what it asks, so no page needs a line to explain itself.
    private var title: String {
        switch page {
        case .who: String(l10n: "Add person")
        case .note: agent == nil ? String(l10n: "What should your agents know about \(who)?")
            : String(l10n: "What should \(reader) know about \(who)?")
        case .role: String(l10n: "What is \(who) to you?")
        case .agents: String(l10n: "Who can \(who) talk to?")
        case .places: String(l10n: "Where does \(who) write from?")
        case .handle: draft.app == "whatsapp" ? String(l10n: "\(who)'s phone number") : String(l10n: "\(who)'s Discord user ID")
        }
    }

    /// Over each page: the agent whose People this is, or a person.
    @ViewBuilder private var mark: some View {
        if let agent {
            AgentGlyph(name: agent, size: SetupMetrics.mark)
        } else {
            Image(systemName: "person.crop.circle").font(IconMetrics.symbol(44, weight: .light))
                .foregroundStyle(FleetStyle.muted).frame(width: SetupMetrics.mark, height: SetupMetrics.mark)
                .accessibilityHidden(true)
        }
    }

    /// Out of the wizard from its first page, and one step back from every other: at the page's top left, and Esc too.
    @ViewBuilder private var backLink: some View {
        if page == .who {
            SetupBack(action: back).keyboardShortcut(.cancelAction).accessibilityIdentifier("add-person-back-people")
        } else {
            SetupBack { step(from: page, back: true) }.keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("add-person-back")
        }
    }

    /// One step on from `from`, or back from it. A Return that the field and the default button both take moves one
    /// step and not two: the second press is no longer on the page it was made on.
    private func step(from: Page, back: Bool = false) {
        guard page == from else { return }
        problem = nil
        switch (from, back) {
        case (.who, false): page = .note
        case (.note, false): page = .role
        case (.note, true): page = .who
        case (.role, false): page = agent == nil ? .agents : .places
        case (.role, true): page = .note
        case (.agents, false): page = .places
        case (.agents, true): page = .role
        case (.places, true): page = agent == nil ? .agents : .role
        case (.handle, true): page = .places
        default: break
        }
    }

    // MARK: one: their name

    private var whoPage: some View {
        SetupStep(title: title) { mark } content: {
            SetupField(placeholder: String(l10n: "Their name"), text: $input.name, wrong: !input.name.isEmpty && nameProblem != nil) {
                if nameProblem == nil { step(from: .who) }
            }.accessibilityIdentifier("new-person-name")
            if !input.name.isEmpty, let why = nameProblem {
                SetupWarning(why).accessibilityIdentifier("new-person-problem")
            } else if nameProblem == nil {
                Button("Continue") { step(from: .who) }
                    .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("add-person-name-on")
            }
        }
    }

    /// What the hub would refuse of the name alone.
    private var nameProblem: String? {
        var one = PersonInput()
        one.name = input.name
        return one.problem(adding: false)
    }

    // MARK: two: the note for the agent

    /// The box starts empty, and what it is for is the line under it, which stays while he types. The note may stay
    /// empty, so Continue is there from the start. Return makes a new line in the note, so Continue takes no key.
    private var notePage: some View {
        SetupStep(title: title) { mark } content: {
            NoteField(text: $input.note).accessibilityIdentifier("new-person-note")
            Text("No secrets: they can get this out of the agent.").foregroundStyle(FleetStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("new-person-note-hint")
            if let why = noteProblem {
                SetupWarning(why).accessibilityIdentifier("new-person-problem")
            } else {
                Button("Continue") { step(from: .note) }
                    .buttonStyle(FleetPrimaryButtonStyle())
                    .accessibilityIdentifier("add-person-note-on")
            }
        }
    }

    /// What the hub would refuse of the name and the note.
    private var noteProblem: String? {
        var one = PersonInput()
        one.name = input.name
        one.note = input.note
        return one.problem(adding: false)
    }

    // MARK: three: what they are to you

    /// Every role at once, one card each. A dropdown hides the roles behind a press and shows one line of one of
    /// them; the owner chooses between people, so he reads them side by side.
    private var rolePage: some View {
        SetupStep(title: title) { mark } content: {
            VStack(spacing: FleetSpace.inside) {
                ForEach(roles) { role in roleCard(role) }
            }
        }
    }

    private func roleCard(_ role: PeopleSnapshot.Role) -> some View {
        Button {
            input.role = role.role
            step(from: .role)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Image(systemName: RoleRow.symbol(role.role)).foregroundStyle(FleetStyle.muted).frame(width: 22)
                VStack(alignment: .leading, spacing: 6) {
                    Text(role.word).fontWeight(.medium).foregroundStyle(FleetStyle.text)
                    // One line in his terms, and what the agent is told on hover (D-2): the step is a choice, not a
                    // page to read.
                    if let line = RoleRow.line(role.role) { Text(line).foregroundStyle(FleetStyle.muted).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(FleetCardButtonStyle())
        .help(role.means)
        .accessibilityIdentifier("add-person-role-\(role.role)")
    }

    // MARK: four: who they can talk to

    private var agentsPage: some View {
        SetupStep(title: title) { mark } content: {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12)], spacing: 12) {
                ForEach(agents) { one in agentTile(one) }
            }
            // A fleet of many agents scrolls: Continue stays in view (`SetupAction`).
            SetupAction {
                Button("Continue") { step(from: .agents) }
                    .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("add-person-agents-on")
            }
        }
    }

    /// One agent: its mark and its name, as the sidebar draws them, and a check mark while it is chosen. An agent
    /// that cannot hold a conversation stays a choice (the hub keeps it on the list and the person reaches it once it
    /// can) and says why on hover, faded.
    private func agentTile(_ one: FleetAgent) -> some View {
        let chosen = input.agents.contains(one.name)
        let why = People.cannotChat(role: one.role, runtime: one.runtime, active: one.active)
        return Button {
            var names = input.agents.filter { $0 != one.name }
            if !chosen { names.append(one.name) }
            input.agents = names.sorted()
        } label: {
            VStack(spacing: 10) {
                AgentGlyph(name: one.name, size: GlyphSize.hero)
                // **The tile fades, the glyph keeps its colour** (B-BRAND-2): the whole tile at 0.5 drew Vps and Nova in
                // colours 25 ΔE from their own beside the sidebar. **Its name fades to the muted words**, which read at
                // 5.5:1 (fix round 3, item 59): the name at half strength read at 4.25:1.
                Text(People.agentWord(one.name)).fontWeight(.medium)
                    .foregroundStyle(why == nil ? FleetStyle.text : FleetStyle.muted).lineLimit(1)
            }
            .padding(.vertical, 20).padding(.horizontal, 12).frame(maxWidth: .infinity).contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                if chosen {
                    Image(systemName: "checkmark").font(IconMetrics.symbol(12, weight: .semibold))
                        .foregroundStyle(FleetStyle.text).padding(12)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius)
                .strokeBorder(chosen ? FleetStyle.accent : .clear, lineWidth: 1.5))
        }
        .buttonStyle(FleetCardButtonStyle())
        .help(why ?? "")
        .accessibilityLabel(People.agentWord(one.name))
        .accessibilityValue([chosen ? String(l10n: "Chosen") : String(l10n: "Not chosen"), why].compactMap { $0 }.joined(separator: ". "))
        .accessibilityIdentifier("person-agent-\(one.name)")
    }

    // MARK: five: where they write from

    @ViewBuilder private var placesPage: some View {
        if busy {
            SetupStep(title: String(l10n: "Adding \(who)"), waits: true) { mark }
        } else {
            SetupStep(title: title) { mark } content: {
                if !input.handles.isEmpty {
                    VStack(spacing: 8) { ForEach(input.handles) { place in placeRow(place) } }
                }
                if input.handles.count < People.handlesMax {
                    HStack(alignment: .top, spacing: 14) { ForEach(People.apps, id: \.self) { app in appCard(app) } }
                }
                SetupAction {
                    if let warning = problem ?? reason { SetupWarning(warning).accessibilityIdentifier("new-person-problem") }
                    if reason == nil, canWrite {
                        Button("Add person") { Task { await add() } }
                            .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("new-person-save")
                    }
                }
            }
        }
    }

    /// One place they write from: the app's own mark and the ID, as their row shows it later, and its removal.
    private func placeRow(_ place: PersonInput.HandleInput) -> some View {
        HStack(spacing: 12) {
            BrandMark(app: place.app, size: 17).foregroundStyle(BrandMark.color(place.app))
            Text(place.handle.split(separator: "@").first.map(String.init) ?? place.handle).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            IconButton(symbol: "trash", words: String(l10n: "Remove this one")) {
                input.handles.removeAll { $0.id == place.id }
            }.accessibilityIdentifier("add-person-remove-\(place.app)")
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
        .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
        .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius).strokeBorder(FleetStyle.line, lineWidth: 0.5))
    }

    /// One chat app, as a card with its own mark: the brand's, never a speech bubble.
    private func appCard(_ app: String) -> some View {
        Button {
            draft = .init(app: app)
            page = .handle
        } label: {
            HStack(spacing: 12) {
                BrandMark(app: app, size: 24).foregroundStyle(BrandMark.color(app))
                Text(ChatApps.title(app)).fontWeight(.medium).foregroundStyle(FleetStyle.text)
                Spacer(minLength: 0)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(FleetCardButtonStyle())
        .accessibilityIdentifier("add-person-app-\(app)")
    }

    // MARK: six: the one field

    private var handlePage: some View {
        SetupStep(title: title) {
            BrandMark(app: draft.app, size: SetupMetrics.mark).foregroundStyle(BrandMark.color(draft.app))
        } content: {
            SetupField(placeholder: People.handlePlaceholder(draft.app), text: $draft.typed,
                       wrong: !draft.typed.isEmpty && draft.problem != nil) { keep() }
                .accessibilityIdentifier("new-person-handle")
            // Where to find it stays under the field while he types; what is wrong with it is said under that.
            Text(People.handleHint(draft.app)).foregroundStyle(FleetStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("add-person-hint")
            if !draft.typed.isEmpty, let why = draft.problem {
                SetupWarning(why).accessibilityIdentifier("add-person-handle-problem")
            } else if draft.problem == nil {
                Button("Add") { keep() }
                    .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("add-person-keep")
            }
        }
    }

    /// The place goes on the person's own list, and the owner is back where every place of theirs is.
    private func keep() {
        guard draft.problem == nil else { return }
        if !input.handles.contains(where: { $0.app == draft.app && $0.handle == draft.handle }) {
            input.handles.append(draft)
        }
        draft = .init()
        page = .places
    }

    // MARK: the hub

    private var reason: String? { input.problem(existing: existing) }

    /// A sender nobody answered opens this wizard: their place is already one of theirs, and their name is filled
    /// in. From one agent's People, the person reaches that agent.
    private func opened() {
        guard !filled else { return }
        filled = true
        if let agent { input.agents = [agent] }
        guard let handle else { return }
        input.handles = [handle]
        if input.name.isEmpty { input.name = People.oneLine(handle.name) }
    }

    private func add() async {
        guard canWrite, reason == nil, let db = store.state?.db else { return }
        busy = true; problem = nil
        defer { busy = false }
        do {
            let receipt = try await client.add(hub: store.hub, database: db, client: store.installation, person: input)
            guard let id = receipt.full?.id ?? receipt.person?.id else { throw HubError.invalidResponse }
            added(id)
        } catch {
            problem = People.reason(error)
        }
    }
}

/// The note the agent reads about a person: a few lines in the one look of the app's fields (`fleetTextBox`: its fill,
/// its 3:1 edge and the violet ring while it has the cursor; fix round 3, item 56, where the ring read 1.9:1), empty until
/// he writes, with the cursor in it when its step opens. Its words start at its left edge, as a setup field's do.
private struct NoteField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(SetupMetrics.textFont)
            .multilineTextAlignment(.leading)
            .padding(5).fleetTextBox(focus: $focused)
            .frame(width: SetupMetrics.field, height: 96)
            .task { focused = true }
    }
}
