import FleetCore
import SwiftUI

/// One person (UI-API.md 1.17): what the agent is told about them, who they may write to, where they write from, and
/// the conversations they have had. Each control saves itself, as in an agent's Settings: a dropdown and a checkbox
/// at once, a field when it loses focus or on Return.
///
/// Remove takes everything of theirs with it — their conversations and every message — so it asks once in its own
/// row, and the line says what goes.
struct PersonPage: View {
    @Bindable var store: FleetStore
    let id: Int
    let snapshot: PeopleSnapshot?
    let back: () -> Void
    let changed: () async -> Void
    let removed: () -> Void
    let open: (Int) -> Void
    /// Opens the page of what this person may use of one agent ("<agent> for <person>", `PersonAccessPage`).
    var openAccess: (String) -> Void = { _ in }

    @State private var name = ""
    @State private var note = ""
    @State private var daily = ""
    @State private var editing: String?
    @State private var saving: [String: SaveState] = [:]
    @State private var newHandle: PersonInput.HandleInput?
    /// Telegram: the link of a person's invite (CHAT-APPS.md 19.4), with the person that it is for, or why there is
    /// none.
    @State private var inviteLink: (person: Int, url: URL)?
    @State private var inviteProblem: String?
    @State private var confirming = false
    @State private var problem: String?
    @FocusState private var focus: String?
    private let client = PeopleClient()

    private var person: PeopleSnapshot.Person? { snapshot?.person(id) }
    private var roles: [PeopleSnapshot.Role] { snapshot?.roleList ?? [] }
    private var now: Double { store.state?.time ?? Date().timeIntervalSince1970 }
    private var canWrite: Bool { store.writesNow && store.state?.db != nil }
    /// The agents a person may reach: every configured agent but the fleet's manager, which the hub refuses.
    private var agents: [FleetAgent] { (store.state?.agents ?? []).filter { $0.role != "manager" } }
    /// The fleet's chat accounts, which say whose agents have a Telegram bot: the store's reading, which the agent
    /// pages keep too (`AgentPage.prefetch`).
    private var channels: ChatAppsSnapshot? { store.reading(AgentPage.channelsName) }

    var body: some View {
        FleetPage(person?.name ?? String(l10n: "Person"), back: FleetBack("People", action: back)) {
            Group {
                if let person {
                    card(person)
                    let access = accessOf(person)
                    PersonAgentsCard(agents: agents, says: says(person),
                                     chosen: Binding(get: { person.agentNames }, set: { names in
                                         Task { await save("agents") { $0.agents = names } }
                                     }), saving: saving["agents"], disabled: !canWrite,
                                     access: access,
                                     accessSaving: saving.reduce(into: [:]) { mine, entry in
                                         if entry.key.hasPrefix("access.") { mine[String(entry.key.dropFirst(7))] = entry.value }
                                     },
                                     chooseAccess: { agent, all in
                                         if !all { openAccess(agent) }
                                         else if access[agent]?.isAll == false { Task { await setAll(agent) } }
                                     },
                                     retryAccess: { agent in Task { await setAll(agent) } })
                    handles(person)
                    conversations(person)
                    remove(person)
                } else {
                    FormSection { FormRow("This person is not there any more", symbol: "person.slash") }
                }
                if let problem {
                    Text(problem).font(FormMetrics.detail).foregroundStyle(.orange).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("person-problem")
                }
            }
        }
        .font(FleetStyle.body).foregroundStyle(FleetStyle.text)
        .task(id: id) { fill() }
        // again when the hub's reading is current again (`isFresh`): a read of an old one does not go
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(id)/\(store.isFresh)") { await readChannels() }
        // the Telegram form that closes, in any way, takes its link with it: the next one asks the kept invite again
        // (`KeptInvite.serves`), which the person may have used since
        .onChange(of: newHandle?.app == "telegram") { _, shows in if !shows { inviteLink = nil; inviteProblem = nil } }
        .onChange(of: person?.name) { if focus != "name" { fill() } }
        .onChange(of: person?.note) { if focus != "note" { fill() } }
        .onChange(of: person?.daily_set) { if focus != "daily" { fill() } }
    }

    /// What this person may use of each agent of their list, where the hub gives it (feature `person_scope`): the select
    /// of the agent's row.
    private func accessOf(_ person: PeopleSnapshot.Person) -> [String: PersonScope] {
        guard store.state?.ui_features?.contains(PersonScope.feature) == true else { return [:] }
        return Dictionary(person.agents.compactMap { agent in agent.scope.map { (agent.agent, $0) } }) { first, _ in first }
    }

    /// The hub's own line for an agent of this person's list that cannot hold a conversation now.
    private func says(_ person: PeopleSnapshot.Person) -> [String: String] {
        Dictionary(uniqueKeysWithValues: person.unreachable.compactMap { agent in
            agent.says.map { (agent.agent, $0) }
        })
    }

    // MARK: who they are

    private func card(_ person: PeopleSnapshot.Person) -> some View {
        FormSection {
            FormRow("Name") {
                HStack(spacing: 8) {
                    SaveMark(state: saving["name"], retry: { Task { await save("name") { $0.name = name } } })
                    TextField(text: $name, prompt: Text(verbatim: "")) { Text("Name") }
                        .fieldPlaceholder(String(l10n: "Name"), shows: name.isEmpty).fleetField(focus: $focus, equals: "name").frame(width: 190)
                        .disabled(!canWrite)
                        .onSubmit { Task { await save("name") { $0.name = name } } }
                        .onChange(of: focus) { old, _ in if old == "name" { Task { await save("name") { $0.name = name } } } }
                        .accessibilityIdentifier("person-name")
                }
            }
            RoleRow(roles: roles, role: Binding(get: { person.role }, set: { role in
                Task { await save("role") { $0.role = role } }
            }), saving: saving["role"], disabled: !canWrite)
            // No symbol on Role, Messages a day and Blocked (the owner, 30 October 2026: "Remove the 3 icons"; margins
            // row 14): the card's titles begin at one edge, 16 points in, with Name and the note's.
            // **With no number to count against, no "of 0"** (the person access plan, section 8): no limit shows, where
            // "0 today of 0" stood for a role with no limit.
            FormRow("Messages a day", detail: person.todayWords) {
                HStack(spacing: 8) {
                    SaveMark(state: saving["daily"], retry: { Task { await saveDaily() } })
                    let usual = (roles.first { $0.role == person.role }?.daily ?? person.dailyLimit).map(String.init) ?? ""
                    TextField(text: $daily, prompt: Text(verbatim: "")) { Text(usual) }
                        .fieldPlaceholder(usual, shows: daily.isEmpty)
                        .fleetField(focus: $focus, equals: "daily").frame(width: 64)
                        .disabled(!canWrite)
                        .onSubmit { Task { await saveDaily() } }
                        .onChange(of: focus) { old, _ in if old == "daily" { Task { await saveDaily() } } }
                        .accessibilityIdentifier("person-daily")
                }
            }
            FormBlock("Note for the agent", detail: String(l10n: "No secrets: they can get this out of the agent.")) {
                // The one field look of a box of several lines (`fleetTextBox`; fix round 3, item 56).
                TextEditor(text: $note).font(FleetStyle.body).fleetTextBox(focus: $focus, equals: "note").frame(height: 72)
                    .disabled(!canWrite)
                    .onChange(of: focus) { old, _ in if old == "note" { Task { await save("note") { $0.note = note } } } }
                    .accessibilityIdentifier("person-note")
            } accessory: {
                SaveMark(state: saving["note"], retry: { Task { await save("note") { $0.note = note } } })
            }
            FormRow("Blocked", detail: person.isBlocked ? String(l10n: "Their messages are dropped.") : nil) {
                HStack(spacing: 8) {
                    SaveMark(state: saving["blocked"], retry: { Task { await block(!person.isBlocked) } })
                    Toggle("", isOn: Binding(get: { person.isBlocked }, set: { value in Task { await block(value) } }))
                        .labelsHidden().toggleStyle(FleetCheckboxStyle()).disabled(!canWrite)
                        .accessibilityIdentifier("person-blocked")
                }
            }
        }
    }

    // MARK: where they write from

    private func handles(_ person: PeopleSnapshot.Person) -> some View {
        FormSection("Writes from") {
            ForEach(person.handles) { handle in
                FormRow(handle.shown, detail: handle.name == nil ? nil : handle.handle) {
                    HStack(spacing: 8) {
                        BrandMark(app: handle.app, size: 13).foregroundStyle(FleetStyle.muted)
                        IconButton(symbol: "trash", words: String(l10n: "Remove this handle")) {
                            Task { await writeHandle(.exact(app: handle.app, handle: handle.handle), delete: true) }
                        }.disabled(!canWrite)
                            .accessibilityIdentifier("person-handle-remove-\(handle.id)")
                    }
                }
            }
            if let draft = newHandle {
                if draft.app == "telegram" { inviteForm(person) } else { handleForm(draft, of: person) }
            }
            if person.handles.isEmpty, newHandle == nil {
                FormRow("No handle yet", symbol: "bubble.left",
                        warning: String(l10n: "Without one they cannot reach \(People.agentWords(person.agentNames))."))
            }
        } accessory: {
            if newHandle == nil, person.handles.count < People.handlesMax {
                Button("Add handle") { newHandle = .init() }.buttonStyle(FleetOutlineButtonStyle())
                    .disabled(!canWrite).accessibilityIdentifier("person-handle-add")
            }
        }
    }

    /// One more place this person writes from. The owner writes their phone number, not a WhatsApp ID: the app
    /// makes the ID and shows what it made (`PersonInput.HandleInput`).
    private func handleForm(_ draft: PersonInput.HandleInput, of person: PeopleSnapshot.Person) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                appChoice(draft, of: person)
                TextField(text: Binding(get: { draft.typed }, set: { newHandle?.typed = $0 }), prompt: Text(verbatim: "")) {
                    Text(People.handlePlaceholder(draft.app))
                }
                    .fieldPlaceholder(People.handlePlaceholder(draft.app), shows: draft.typed.isEmpty)
                    .fleetField().frame(width: 220)
                    .onSubmit { Task { await writeHandle(draft) } }
                    .accessibilityIdentifier("person-handle-id")
                Spacer(minLength: 8)
                Button("Cancel") { newHandle = nil }.buttonStyle(FleetOutlineButtonStyle())
                Button("Add") { Task { await writeHandle(draft) } }.buttonStyle(FleetPrimaryButtonStyle())
                    .disabled(!canWrite || draft.problem != nil).accessibilityIdentifier("person-handle-save")
            }
            Text(handleLine(draft))
                .font(FormMetrics.detail)
                .foregroundStyle(draft.problem != nil && !draft.typed.isEmpty ? .orange : FleetStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 12)
    }

    /// The chat app of a new handle: Telegram too on a hub that serves it, for a person with an agent on Telegram (the
    /// owner's "Yes, as recommended" of 17 November 2026), whose handle comes from an invite. While Telegram is the
    /// choice, it stays one of the options.
    private func appChoice(_ draft: PersonInput.HandleInput, of person: PeopleSnapshot.Person) -> some View {
        let served = store.state?.ui_features?.contains(ChatApps.telegramFeature) == true
        let telegram = served && (draft.app == "telegram" || !telegramAgents(of: person, in: channels).isEmpty)
        let apps = People.apps + (telegram ? ["telegram"] : [])
        return FleetSelect("App", selection: Binding(get: { draft.app }, set: { newHandle?.app = $0 }),
                           options: apps.map { FleetOption($0, ChatApps.title($0), mark: .chatApp($0)) })
            .accessibilityIdentifier("person-handle-app")
    }

    /// Telegram (CHAT-APPS.md 19.4): Telegram's apps do not show a person their ID, so in place of a field the person's
    /// own invite link to the bot of one of their agents, as a QR code and as a link with Copy. Their Telegram is theirs
    /// when they open it and press Start; the row then shows here by itself.
    private func inviteForm(_ person: PeopleSnapshot.Person) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                appChoice(newHandle ?? .init(app: "telegram"), of: person)
                Spacer(minLength: 8)
                Button("Cancel") { newHandle = nil; inviteLink = nil; inviteProblem = nil }.buttonStyle(FleetOutlineButtonStyle())
            }
            if let link = inviteLink.flatMap({ $0.person == person.id ? $0.url : nil }) {
                HStack(alignment: .center, spacing: 14) {
                    QRCodeView(text: link.absoluteString, size: 132).accessibilityIdentifier("person-invite-qr")
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(verbatim: link.absoluteString).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                .accessibilityIdentifier("person-invite-link")
                            MessageAction(symbol: "square.on.square", label: String(l10n: "Copy link")) { copyMessage(link.absoluteString) }
                                .foregroundStyle(FleetStyle.muted)
                        }
                        Text("\(person.name) opens it and presses Start. It works for 7 days.")
                            .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if let inviteProblem {
                Text(inviteProblem).font(FormMetrics.detail).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("person-invite-problem")
            }
            // While the hub makes the link, no line shows (the owner's "Yes, as recommended" of 17 November 2026).
        }
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 12)
        // again when the app may write again (`canWrite`, which is `writesNow`): the link comes by itself
        .task(id: "\(person.id)/\(canWrite)") { await makeInvite(person) }
    }

    /// The fleet's chat accounts again as the page opens, on a hub that serves Telegram: Add handle offers Telegram
    /// from them. A read that fails keeps the last reading.
    private func readChannels() async {
        guard store.state?.ui_features?.contains(ChatApps.telegramFeature) == true, store.isFresh,
              let db = store.state?.db else { return }
        let start = store.pageReadStart()
        if let fresh = try? await AgentPage.readAccounts(store, hub: store.hub, database: db, from: start), !Task.isCancelled {
            store.keep(fresh, as: AgentPage.channelsName, from: start)
        }
    }

    /// The person's agents whose Telegram bot can take their invite now, in the order of their list: a bot that is on
    /// and has said its name (`telegramInviteAccount`, the hub's own test).
    private func telegramAgents(of person: PeopleSnapshot.Person, in accounts: ChatAppsSnapshot?) -> [String] {
        person.agentNames.filter { accounts?.canInviteOnTelegram(to: $0) == true }
    }

    /// The invite, for the first of the person's agents that has a Telegram bot. Add handle offers Telegram only for a
    /// person who has one; when the accounts read here show none of theirs any more, the form closes, as Cancel
    /// closes it, and Telegram is no longer offered.
    private func makeInvite(_ person: PeopleSnapshot.Person) async {
        // a link of this person that shows stays: a reading that is current again makes no new one
        guard canWrite, let db = store.state?.db, inviteLink?.person != person.id else { return }
        inviteLink = nil; inviteProblem = nil
        let chat = ChatAppsClient(), hub = store.hub
        do {
            var accounts: ChatAppsSnapshot
            // A write can change which bot may issue the invite while the accounts are on their way.
            repeat {
                let start = store.pageReadStart()
                accounts = try await AgentPage.readAccounts(store, hub: hub, database: db, from: start)
                guard !Task.isCancelled, store.hub == hub, store.state?.db == db, canWrite else { return }
                if store.keep(accounts, as: AgentPage.channelsName, from: start) { break }
            } while true
            // the agent of the invite that this Mac keeps, while it is still theirs and on Telegram: the hub keeps one
            // open invite for each person, so another agent's would stop the link that the owner sent
            let onTelegram = telegramAgents(of: person, in: accounts)
            let kept = store.keptInviteAgent(for: person)
            guard let agent = onTelegram.first(where: { $0 == kept }) ?? onTelegram.first,
                  let bot = accounts.telegramInviteAccount(of: agent) else {
                if newHandle?.app == "telegram" { newHandle = nil }
                return
            }
            let made = try await store.telegramInvite(for: person, agent: agent, bot: bot) {
                try await chat.makeInvite(hub: hub, database: db, client: store.installation, person: person.id, agent: agent)
            }
            guard !Task.isCancelled, store.hub == hub, store.state?.db == db else { return }
            // the link on the bot that the invite is for, as the setup steps take it (`LinkCode.link(on:)`)
            guard let link = made.link(on: bot.id) else {
                inviteProblem = String(l10n: "The hub gave no link.")
                return
            }
            inviteLink = (person.id, link)
        } catch {
            // a read that the form stopped (it closed, or the hub's reading turned old) says nothing
            if !Task.isCancelled, store.hub == hub, store.state?.db == db { inviteProblem = People.reason(error) }
        }
    }

    /// One line under the field: what the app made of what the owner wrote, what is wrong with it, or what to write.
    private func handleLine(_ draft: PersonInput.HandleInput) -> String {
        if draft.typed.isEmpty { return People.handleHint(draft.app) }
        if let why = draft.problem { return why }
        return String(l10n: "\(ChatApps.title(draft.app)) ID: \(draft.handle)")
    }

    // MARK: their conversations

    @ViewBuilder private func conversations(_ person: PeopleSnapshot.Person) -> some View {
        if !person.conversations.isEmpty {
            FormSection("Conversations") {
                ForEach(person.conversations) { conversation in
                    Button { open(conversation.id) } label: {
                        HStack(spacing: 0) {
                            RowMark { AgentGlyph(name: conversation.agent, size: GlyphSize.row) }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(People.agentWord(conversation.agent)).font(FormMetrics.title).foregroundStyle(FleetStyle.text)
                                Text(conversation.state == "paused" ? String(l10n: "Paused") : conversation.last.map {
                                    String(l10n: "Last message \(activityAge($0, now: now).lowercased())")
                                } ?? String(l10n: "No message yet"))
                                    .font(FormMetrics.detail)
                                    .foregroundStyle(conversation.state == "paused" ? .orange : FleetStyle.muted)
                            }
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.right").font(IconMetrics.symbol(11, weight: .semibold))
                                .foregroundStyle(FleetStyle.muted)
                        }
                        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 11).frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(FleetRowButtonStyle()).accessibilityIdentifier("person-conversation-\(conversation.id)")
                }
            }
        }
    }

    // MARK: remove

    @ViewBuilder private func remove(_ person: PeopleSnapshot.Person) -> some View {
        if confirming {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(IconMetrics.symbol(13)).foregroundStyle(.orange)
                Text(person.conversations.isEmpty
                     ? "Everything of theirs goes. There is no undo."
                     : "Their \(person.conversations.count) conversations and every message go. There is no undo.")
                    .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Cancel") { confirming = false }.buttonStyle(FleetOutlineButtonStyle())
                Button("Remove person") { Task { await removePerson(person) } }.buttonStyle(FleetDangerButtonStyle())
                    .disabled(!canWrite).accessibilityIdentifier("person-remove-confirm")
            }
        } else {
            Button("Remove person") { confirming = true; problem = nil }.buttonStyle(FleetDangerButtonStyle())
                .disabled(!canWrite).help("Removes them, their conversations and every message of them.")
                .accessibilityIdentifier("person-remove")
        }
    }

    // MARK: saving

    private func fill() {
        guard let person else { return }
        name = person.name
        note = person.note ?? ""
        daily = person.daily_set.map(String.init) ?? ""
    }

    /// One change of one field, against the person as the hub has them. Nothing to change writes nothing.
    private func save(_ field: String, _ change: (inout PersonInput) -> Void) async {
        guard let person, canWrite, let db = store.state?.db else { return }
        var input = PersonInput(person)
        change(&input)
        if let why = input.problem(adding: false) {
            saving[field] = .failed(why); problem = why
            return
        }
        saving[field] = .saving; problem = nil
        do {
            let receipt = try await client.change(hub: store.hub, database: db, client: store.installation,
                                                  person: person, to: input)
            saving[field] = receipt == nil ? nil : .saved
            await changed()
            if receipt != nil { markSaved(field) }
        } catch {
            saving[field] = .failed(People.reason(error))
            problem = People.reason(error)
            await changed()
        }
    }

    private func saveDaily() async {
        let said = daily.trimmingCharacters(in: .whitespacesAndNewlines)
        guard said.isEmpty || Int(said) != nil else {
            saving["daily"] = .failed(String(l10n: "Write a number, or nothing for the role's own number."))
            problem = String(l10n: "Write a number, or nothing for the role's own number.")
            return
        }
        await save("daily") { $0.daily = said.isEmpty ? nil : Int(said) }
    }

    /// **All access with one agent of their list**, chosen in its row's select: one write of that agent alone, as the
    /// page's other fields save themselves. Try again sends All again.
    private func setAll(_ agent: String) async {
        guard let person, canWrite, let db = store.state?.db else { return }
        let field = "access.\(agent)"
        saving[field] = .saving; problem = nil
        do {
            _ = try await client.scope(hub: store.hub, database: db, client: store.installation, person: person.id,
                                       agent: agent, list: nil)
            saving[field] = .saved
            await changed()
            markSaved(field)
        } catch {
            saving[field] = .failed(People.reason(error))
            problem = People.reason(error)
            await changed()
        }
    }

    private func block(_ blocked: Bool) async {
        guard let person, canWrite, let db = store.state?.db else { return }
        saving["blocked"] = .saving; problem = nil
        do {
            _ = try await client.block(hub: store.hub, database: db, client: store.installation,
                                       person: person.id, blocked: blocked)
            saving["blocked"] = .saved
            await changed()
            markSaved("blocked")
        } catch {
            saving["blocked"] = .failed(People.reason(error))
            problem = People.reason(error)
        }
    }

    private func writeHandle(_ handle: PersonInput.HandleInput, delete: Bool = false) async {
        guard let person, canWrite, let db = store.state?.db else { return }
        if !delete, let why = handle.problem { problem = why; return }
        problem = nil
        // a Telegram handle that goes takes the kept invite with it, before the hub's answer, which can be lost: the
        // person may have used its code. An open Telegram form closes with it, as a write that goes through closes
        // it, so a refused delete leaves no empty form
        if delete, handle.app == "telegram" {
            store.forgetTelegramInvite(of: person.id)
            inviteLink = nil
            if newHandle?.app == "telegram" { newHandle = nil }
        }
        do {
            _ = try await client.handle(hub: store.hub, database: db, client: store.installation,
                                        person: person.id, handle: handle, delete: delete)
            newHandle = nil
            await changed()
        } catch {
            problem = People.reason(error)
            await changed()
        }
    }

    private func removePerson(_ person: PeopleSnapshot.Person) async {
        guard canWrite, let db = store.state?.db else { return }
        problem = nil
        do {
            _ = try await client.remove(hub: store.hub, database: db, client: store.installation, person: person.id)
            confirming = false
            removed()
        } catch {
            problem = People.reason(error)
            confirming = false
        }
    }

    /// "Saved" stays for a moment, as every other control that saves itself.
    private func markSaved(_ field: String) {
        Task {
            try? await Task.sleep(for: .seconds(2))
            if saving[field] == .saved { saving[field] = nil }
        }
    }
}

extension FleetStore {
    /// A person's Telegram invite: the one that this Mac keeps, while a visit may show it again
    /// (`KeptInvite.serves`), else a new one from the hub. A new one always takes the kept one's place, because the
    /// hub has just deleted that one's code: it is kept only with a link on its bot (`KeptInvite.init`), and else
    /// nothing is kept, so the next visit asks the hub again.
    func telegramInvite(for person: PeopleSnapshot.Person, agent: String, bot: ChatAppsSnapshot.Account?,
                        make: () async throws -> LinkCode) async throws -> LinkCode {
        let name = "people.invite.\(person.id)"
        if let kept: KeptInvite = reading(name),
           kept.serves(person, agent: agent, bot: bot, serverTime: state?.time ?? 0, readAt: lastSuccess ?? Date(), now: Date()) {
            return kept.invite
        }
        let address = hub, database = state?.db
        let made = try await make()
        guard hub == address, state?.db == database else { throw CancellationError() }
        keep(KeptInvite(made, person: person, agent: agent, bot: bot), as: name)
        return made
    }

    /// No kept invite for this person: their Telegram handle went, so its code may be used already, and a visit
    /// that showed it again would give a link that no longer works.
    func forgetTelegramInvite(of person: Int) {
        keep(nil, as: "people.invite.\(person)")
    }

    /// The agent of the invite that this Mac keeps for this person, or nil.
    func keptInviteAgent(for person: PeopleSnapshot.Person) -> String? {
        guard let kept: KeptInvite = reading("people.invite.\(person.id)"), kept.added == person.added else { return nil }
        return kept.agent
    }
}
