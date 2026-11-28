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
///   5. **Where does Ana write from?** Only for a sender nobody answered (Settings › People › Wrote and was not
///      answered, Add): the ID that the chat app really sent, which nobody can change here, and Add person.
///
/// **No field takes a number or an ID** (the owner's "From 'Wrote and was not answered', with Add" of 26 November 2026
/// to question 3 of `channels-2026-11-26`: "A typed number is only a claim"). A person whom Add person opened with no
/// sender has no place here: the last step of the ones above adds them (Add person on step four, and a role's card on
/// step three where step four is left out). A button shows only while it can be pressed, and while the hub adds the
/// person the title is its moving words. The hub takes the whole person in one command (`POST /ui/people`).
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

    enum Page { case who, note, role, agents, places }

    @State private var page = Page.who
    @State private var input = PersonInput()
    @State private var busy = false
    @State private var problem: String?
    @State private var filled = false
    private let client = PeopleClient()

    private var canWrite: Bool { store.writesNow && store.state?.db != nil && !busy }
    /// The agents a person may reach: every configured agent but the fleet's manager, which the hub refuses.
    private var agents: [FleetAgent] { (store.state?.agents ?? []).filter { $0.role != "manager" } }
    /// Who they are, in the titles after the first page.
    private var who: String { People.oneLine(input.name) }
    /// Who reads the note: the agent whose People this is, or every agent they will talk to.
    private var reader: String { agent.map(People.agentWord) ?? "your agents" }

    /// The step that adds the person: Where does Ana write from? for a sender nobody answered, else the last one before.
    private var last: Page { Self.last(agent: agent, places: !input.handles.isEmpty) }

    var body: some View {
        // Back stands at the page's top left, where every setup page has it.
        SetupPage { backLink } step: {
            Group {
                if busy {
                    SetupStep(title: String(l10n: "Adding \(who)"), waits: true) { mark }
                } else {
                    switch page {
                    case .who: whoPage
                    case .note: notePage
                    case .role: rolePage
                    case .agents: agentsPage
                    case .places: placesPage
                    }
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

    /// One step on from `from`, or back from it; on from the last step, the hub adds the person. A Return that the
    /// field and the default button both take moves one step and not two: the second press is no longer on the page it
    /// was made on.
    private func step(from: Page, back: Bool = false) {
        guard page == from else { return }
        problem = nil
        if !back, from == last {
            Task { await add() }
            return
        }
        if let next = Self.next(from: from, back: back, agent: agent) { page = next }
    }

    /// **The page after `from`, or before it**, or nil where there is none: step four only with no agent of the page
    /// around, and step five only when the person has a place (`last`).
    static func next(from: Page, back: Bool, agent: String?) -> Page? {
        switch (from, back) {
        case (.who, false): .note
        case (.note, false): .role
        case (.note, true): .who
        case (.role, false): agent == nil ? .agents : .places
        case (.role, true): .note
        case (.agents, false): .places
        case (.agents, true): .role
        case (.places, true): agent == nil ? .agents : .role
        default: nil
        }
    }

    /// **The step whose way on adds the person**: Where does Ana write from? for a person with a place (a sender
    /// nobody answered), else step four, or step three where the agent of the page left step four out. A person with
    /// no place never sees a step five with nothing on it.
    static func last(agent: String?, places: Bool) -> Page {
        places ? .places : agent == nil ? .agents : .role
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
            // The last step where a role's card adds the person: what the hub refused stays under the cards.
            if last == .role, let problem { SetupWarning(problem).accessibilityIdentifier("new-person-problem") }
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
            // A fleet of many agents scrolls: the way on stays in view (`SetupAction`).
            SetupAction {
                if last == .agents {
                    adding
                } else {
                    Button("Continue") { step(from: .agents) }
                        .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("add-person-agents-on")
                }
            }
        }
    }

    /// One agent: its mark and its name, as the sidebar draws them, and a check mark while it is chosen. An agent
    /// that cannot hold a conversation stays a choice (the hub keeps it on the list and the person reaches it once it
    /// can) and says why on hover, faded.
    private func agentTile(_ one: FleetAgent) -> some View {
        let chosen = input.agents.contains(one.name)
        let why = People.cannotChat(role: one.role, runtime: one.runtime, active: one.active, provider: one.modelProvider)
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

    private var placesPage: some View {
        SetupStep(title: title) { mark } content: {
            VStack(spacing: 8) { ForEach(input.handles) { place in placeRow(place) } }
            SetupAction { adding }
        }
    }

    /// The way on of the last step: what the hub would refuse or refused, and the white Add person.
    @ViewBuilder private var adding: some View {
        if let warning = problem ?? reason { SetupWarning(warning).accessibilityIdentifier("new-person-problem") }
        if reason == nil, canWrite {
            Button("Add person") { Task { await add() } }
                .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("new-person-save")
        }
    }

    /// One place they write from: the app's own mark and the ID that the chat app sent, as their row shows it later.
    /// It has no control: nobody changes the ID that the app sent.
    private func placeRow(_ place: PersonInput.HandleInput) -> some View {
        HStack(spacing: 12) {
            BrandMark(app: place.app, size: 17).foregroundStyle(BrandMark.color(place.app))
            Text(place.handle.split(separator: "@").first.map(String.init) ?? place.handle).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
        .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius).strokeBorder(FleetStyle.line, lineWidth: 0.5))
        .accessibilityIdentifier("add-person-place-\(place.app)")
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
        guard canWrite, let db = store.state?.db else { return }
        // A role's card that adds the person has no place for the line of a refusal before the press: it says it after.
        if let reason { problem = reason; return }
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
