import FleetCore
import SwiftUI

/// What Add secret starts from: an agent's request for one secret, the chat that it was opened from, a key that the
/// owner pasted there, or nothing. It is not Codable and nothing keeps it: a pasted key is in it only until the form
/// takes it.
struct SecretPreset: Identifiable {
    let id = UUID()
    /// The request that the save answers (owner feature `secret_requests`).
    var need: Int?
    var kind = LoginSecret.Kind.apiKey
    var env = ""
    var url = ""
    /// What each agent gets: the request's proposal, which the owner changes in the form.
    var give: [String: SecretGrant] = [:]
    /// The agent of the chat that Add secret was opened from. After the save, the owner's message there names the
    /// secret and who holds it, never its value.
    var tell: String?
    /// A key that the owner pasted into a chat and saves here instead. It goes into the form's field and nowhere else.
    var key: String?

    init(tell: String? = nil, key: String? = nil, give: [String: SecretGrant] = [:]) { self.tell = tell; self.key = key; self.give = give }

    init(need: OwnerNeed) {
        let asked = need.secret ?? NeedSecret(kind: .apiKey)
        self.need = need.id
        kind = asked.kind; env = asked.env ?? ""; url = asked.site ?? ""; give = asked.give
    }
}

/// What came of a save once the central vault had it, step by step: who got it, the request that it answers and the
/// chat that it tells. Nothing in it is a value: the sealed value opens only in the central vault.
struct SecretProgress: Equatable {
    struct Grant: Equatable {
        let agent: String
        let grant: SecretGrant
        var done = false
        /// What the owner must know about this agent's access, or why it is not given.
        var note: String?
        var warning = false
    }
    let login: String
    let title: String
    let kind: LoginSecret.Kind
    var grants: [Grant]
    let need: Int?
    /// The one answer of the request, so that a retry is that answer again and never a second one.
    let answerID = UUID()
    var answered = false
    /// The hub's words when the request had its answer already.
    var answerNote: String?
    var answerProblem: String?
    let tell: String?
    var told = false
    var tellProblem: String?
    /// A save into the central vault: the value sealed to its key, until the vault has it. Only that vault opens it,
    /// and nothing after it runs before it is there.
    var sealed: String?
    var sealedProblem: String?

    var isDone: Bool {
        sealed == nil && grants.allSatisfy(\.done) && (need == nil || answered) && (tell == nil || told)
    }
    var given: [Grant] { grants.filter(\.done) }
}

/// Add secret: the owner types one login or one API key, and the fleet's central vault keeps it (owner feature
/// `central_vault`). It is the one way a value reaches a server (DevOps plan V1): the central vault gives it to each
/// server whose agents get it, for a grant that the owner signed. The owner types no name: a login shows as
/// "host · user name", an API key by its variable name. The values are only in this view's state, and they are cleared
/// once the hub has the reference, on Cancel and when the view goes away. No draft, outbox record or log gets them.
///
/// The form saves only while the hub names, as the central vault's key, the key this Mac pinned at Set up. The form
/// makes the reference itself (`bws://<uuid4>`), seals the value to that key, registers the reference with the hub (its
/// fingerprints, made here from the hub's salts, and its catalog entry), and sends the sealed value. The central vault
/// keeps it only when its own fingerprints of what it opens are the registered ones. Then, in order: the agents that
/// the owner chose get it, each grant signed with the owner key (`GrantSigning`), the request that the form answers
/// gets its answer (owner feature `secret_requests`), and the chat that it was opened from gets one message of the
/// owner's that names the secret and who holds it. A step that fails is shown with its words and Try again; the steps
/// before it stay done.
///
/// **If the central vault does not answer, nothing is sent** (DevOps plan V4), also as no fallback: the form shows the
/// row "Founderizer Vault does not answer" and its Try again in place of the fields, and the hub refuses a new
/// secret then too (503). The fields keep what was typed until the form goes.
struct SecretEntryView: View {
    @Bindable var store: FleetStore
    private let preset: SecretPreset
    /// A request's form, in its card in a chat or under the request at hand on Needs you: no headings of its own.
    private let compact: Bool
    /// The reference of the saved secret, or nil when the owner closed the form without one.
    let onDone: (String?) -> Void

    /// The hub features of Add secret and its grants. Show the Add button only with them.
    static let feature = "secrets"
    static func isOffered(by store: FleetStore) -> Bool {
        let features = store.state?.ui_features ?? []
        return features.contains(feature) && features.contains("secret_grants")
    }

    private enum Phase: Equatable { case form, noVault, saved(SecretProgress) }
    /// The detail of the row "Founderizer Vault does not answer" while the central vault does not answer: new words
    /// in an existing row, which wait for the owner's yes (AGENTS.md).
    static let noVaultDetail: String? = "Nothing was sent. Try again in a moment."
    @State private var phase: Phase
    @State private var login: LoginSecret
    /// The access that each agent gets, by name. An agent that is not in it gets none.
    @State private var access: [String: SecretGrant]
    /// The authenticator seed field shows.
    @State private var withSeed = false
    /// The last problem or the next step, in orange.
    @State private var message: String?
    @State private var busy = false
    /// The owner saw that the catalog has this title and pressed Save again.
    @State private var sameName: String?
    /// One secret of the catalog that fits the request: an earlier save can answer it.
    private struct Fit: Identifiable {
        let login: String
        let entry: TeamLogin
        var id: String { login }
    }
    @State private var fitting: [Fit] = []
    /// The owner says no to the request with one press of Decline: no reason, no second step (the owner, 30 October
    /// 2026: "remove the option, pressing decline should be enough").
    @State private var declineID = UUID()
    /// The hub address and the generation when this form opened. A later connection change in the store ends its use.
    @State private var hub: URL
    @State private var database: String?
    private let client = HubClient()
    /// The central vault's key, which the form seals to, read as it opens and at each Try again; nil while it is not
    /// known, and Save waits for it.
    @State private var central: String?
    /// The reference of a central save that the hub did not confirm: the same Save again goes under it, so a save that
    /// did reach the catalog is not added twice. Any change of the fields drops it.
    @State private var centralLogin: String?
    /// The form stands under the title of a step: the request at hand on Needs you (`NeedStep`).
    @Environment(\.stepText) private var stepText

    init(store: FleetStore, preset: SecretPreset = SecretPreset(), compact: Bool = false, onDone: @escaping (String?) -> Void) {
        self.store = store; self.preset = preset; self.compact = compact; self.onDone = onDone
        _hub = State(initialValue: store.hub); _database = State(initialValue: store.state?.db)
        // The form shows at once and waits for the central vault's key before Save; a hub without it shows the row.
        _phase = State(initialValue: store.state?.ui_features?.contains(CentralVault.feature) == true ? .form : .noVault)
        var login = Self.blank(preset)
        if let key = preset.key { login.password = key }
        _login = State(initialValue: login)
        _access = State(initialValue: preset.give)
    }

    /// The hub and the generation of this view, while the store still shows them and its reading is current.
    private var context: (hub: URL, db: String)? {
        guard let database, store.hub == hub, store.state?.db == database, store.isFresh, Self.isOffered(by: store) else { return nil }
        return (hub, database)
    }

    private var features: [String] { store.state?.ui_features ?? [] }
    private var isRequest: Bool { preset.need != nil }
    /// A request's form on a step: what it draws stands in the middle, as a step's field and its button do.
    private var onStep: Bool { stepText != nil && isRequest }
    /// **On a step, a request that names all but the value is the fields for the value alone** (the owner's yes of 11
    /// November 2026 to the picture of a request at hand: a Key field, Save, Decline): its site, and for a key its
    /// variable, stand in the request's own title. Any other request keeps the rows of its card there.
    private var fieldsAlone: Bool { onStep && knowsSite && (login.kind == .login || !preset.env.isEmpty) }
    /// Save can go: the vault's key is known, and what he typed is a login or a key.
    private var canSave: Bool { !busy && central != nil && login.problem == nil && context != nil }
    /// A request that names its site keeps it: the card's title already says the host, so the form asks for no address.
    private var knowsSite: Bool { isRequest && !preset.url.isEmpty }
    /// A request whose proposal names one agent is for that agent: the save gives it what it asked for, with no list.
    private var forOneAgent: Bool { isRequest && preset.give.count == 1 }
    private var need: OwnerNeed? { preset.need.flatMap { id in store.state?.needs.first { $0.id == id } } }
    /// The agents that can hold a secret: the workers and the leads, in the hub's order.
    private var holders: [String] { store.state?.agents.filter { ["worker", "lead"].contains($0.role) }.map(\.name) ?? [] }
    /// The grants that the owner chose, in the hub's order of the agents. A login is never read.
    private var chosen: [SecretProgress.Grant] {
        holders.compactMap { agent in
            access[agent].map { SecretProgress.Grant(agent: agent, grant: login.kind == .login ? .use : $0) }
        } + doorGrant
    }
    /// The door, where the request gives it the secret (DevOps plan C5): it has no row, and Save gives it to the door
    /// with the owner's signed grant, as to an agent. A form that no request opened never gives the door anything.
    private var doorGrant: [SecretProgress.Grant] {
        isRequest && access[DoorAccess.holder] != nil ? [SecretProgress.Grant(agent: DoorAccess.holder, grant: .use)] : []
    }

    var body: some View {
        VStack(alignment: onStep ? .center : .leading, spacing: 14) {
            switch phase {
            // **An error is its line and one sentence, with no footer that explains** (fix round 3, item 35).
            case .noVault:
                FormSection(compact ? nil : "Add secret") {
                    FormRow("Founderizer Vault does not answer", detail: Self.noVaultDetail) {
                        Button("Try again") { Task { await start() } }.buttonStyle(FleetOutlineButtonStyle()).disabled(busy)
                            .accessibilityIdentifier("secret-vault-retry")
                    }
                }
            case .form:
                if !fitting.isEmpty { fits }
                form
                if !holders.isEmpty && !forOneAgent { accessChoice.disabled(busy) }
            case .saved(let progress): saved(progress)
            }
            if let message {
                Text(message).font(FormMetrics.onStep(onStep ? stepText : nil) ?? FormMetrics.detail).foregroundStyle(.orange)
                    .multilineTextAlignment(onStep ? .center : .leading).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled).accessibilityIdentifier("secret-message")
            }
            if onStep { stepActions } else { actions }
        }
        // **The form's width** (margins row 26): Add secret's cards take the 680 points of every form page's cards, as a
        // secret request's form does in its card in a chat. It stood 560, 120 points short of the cards beside it.
        // Under a request at hand it stands in the middle of the step, as its title does.
        .frame(maxWidth: FormMetrics.formWidth, alignment: onStep ? .center : .leading)
        .task { await start() }
        .task(id: preset.need) { await readFits() }
        .onDisappear { clear() }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            Spacer()
            if case .saved(let progress) = phase {
                if !progress.isDone {
                    Button("Try again") { Task { await proceed(progress) } }.buttonStyle(FleetOutlineButtonStyle())
                        .disabled(busy || context == nil).accessibilityIdentifier("secret-retry")
                }
                Button("Done") { onDone(progress.login) }.buttonStyle(FleetPrimaryButtonStyle()).disabled(busy)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("secret-done-saving")
            } else {
                if isRequest {
                    Button("Decline") { Task { await decline() } }.buttonStyle(FleetOutlineButtonStyle())
                        .disabled(busy || context == nil)
                        .help("Tell \(need?.by.agentLabel ?? "the agent") that you do not give it").accessibilityIdentifier("secret-decline")
                }
                if !isRequest {
                    Button(phase == .form ? "Cancel" : "Close") { clear(); onDone(nil) }.buttonStyle(FleetOutlineButtonStyle())
                        .keyboardShortcut(.cancelAction).disabled(busy).accessibilityIdentifier("secret-cancel")
                }
                if phase == .form {
                    Button(saveLabel) { Task { await save() } }.buttonStyle(FleetPrimaryButtonStyle())
                        .disabled(!canSave).accessibilityIdentifier("secret-save")
                }
            }
        }
    }

    private var saveLabel: String { preset.tell.map { "Save and tell \($0.agentLabel)" } ?? "Save" }

    /// **The same actions under a request at hand, in the middle** (`onStep`): Save, the step's one button, and Decline
    /// as the quiet link under it, where a step has its way back; after a save, Try again and Done.
    @ViewBuilder private var stepActions: some View {
        if case .saved(let progress) = phase {
            HStack(spacing: 8) {
                if !progress.isDone {
                    Button("Try again") { Task { await proceed(progress) } }.buttonStyle(FleetOutlineButtonStyle())
                        .disabled(busy || context == nil).accessibilityIdentifier("secret-retry")
                }
                Button("Done") { onDone(progress.login) }.buttonStyle(FleetPrimaryButtonStyle()).disabled(busy)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("secret-done-saving")
            }
        } else {
            VStack(spacing: 14) {
                // The second click of a double-click on the request before this one presses nothing here (`SecondClick`).
                if phase == .form {
                    Button(saveLabel) { if !SecondClick.isNow { Task { await save() } } }.buttonStyle(FleetPrimaryButtonStyle())
                        .disabled(!canSave).accessibilityIdentifier("secret-save")
                }
                SetupLink("Decline") { if !SecondClick.isNow { Task { await decline() } } }.disabled(busy || context == nil)
                    .help("Tell \(need?.by.agentLabel ?? "the agent") that you do not give it").accessibilityIdentifier("secret-decline")
            }
        }
    }

    /// One field of a request at hand: the app's field in the step's size (`setupField`), its name as its placeholder,
    /// no wider than a step's field. Return saves, as Return is a step's way on.
    @ViewBuilder private func stepField(_ words: String, text: Binding<String>, secure: Bool, id: String) -> some View {
        Group {
            if secure { SecureField(text: text, prompt: Text(verbatim: "")) { Text(words) } }
            else { TextField(text: text, prompt: Text(verbatim: "")) { Text(words) } }
        }
        .fieldPlaceholder(words, shows: text.wrappedValue.isEmpty)
        .modifier(FleetFieldLook(text: SetupMetrics.text, height: SetupMetrics.fieldHeight))
        .frame(maxWidth: SetupMetrics.field)
        .onSubmit { if canSave { Task { await save() } } }
        .accessibilityIdentifier(id)
    }

    /// The fields of a request that names all but the value (`fieldsAlone`).
    private var stepFields: some View {
        VStack(spacing: 10) {
            if login.kind == .login {
                stepField("User name or email", text: $login.username, secure: false, id: "secret-user")
                stepField("Password", text: $login.password, secure: true, id: "secret-password")
            } else {
                stepField("Key", text: $login.password, secure: true, id: "secret-password")
            }
            // In the middle, as the step's lines are: the line's own row keeps its words at its leading edge.
            waitRow.fixedSize()
        }
    }

    /// **The app's one loading look, as the last row of the section it is about** (T-13; review B1, fix round 2): nothing
    /// for a second, then the moving words, never a spinner. It stood in the actions row, straight in the card over the
    /// page, where moving words made each frame of a card take 241–325 ms (the 28 October rule).
    @ViewBuilder private var waitRow: some View {
        if busy || (phase == .form && central == nil) {
            Held { LoadingLine(busy ? "Saving…" : "Reading Founderizer Vault…", waits: false).padding(.vertical, 12) }
        }
    }

    private var form: some View {
        Group { if fieldsAlone { stepFields } else { rows } }
            .disabled(busy)
            .onChange(of: login.kind) { _, kind in
                // The other kind's fields go: a password never becomes a key, and the reverse.
                var fresh = LoginSecret(); fresh.kind = kind
                login = fresh; withSeed = false; sameName = nil; message = nil
            }
            .onChange(of: login.title) { _, _ in sameName = nil }
            .onChange(of: login) { _, _ in centralLogin = nil }
    }

    private var rows: some View {
        // The page header or the request's card says what this is: the form's card has no heading of its own, and a
        // request's form has no footer either (the owner, 29 October 2026: "the panel should be much more compact").
        FormSection(footer: isRequest ? nil : footer) {
            if !isRequest {
                FormRow("Kind") {
                    FleetSegmented("Kind", selection: $login.kind,
                                   options: [FleetOption(LoginSecret.Kind.login, "Login"), FleetOption(LoginSecret.Kind.apiKey, "API key")])
                        .accessibilityIdentifier("secret-kind")
                }
            }
            if login.kind == .login {
                if !knowsSite {
                    FormRow("Address", detail: "The sign-in page, with https://.") {
                        TextField(text: $login.url, prompt: Text(verbatim: "")) { Text("https://") }
                            .fieldPlaceholder("https://", shows: login.url.isEmpty).fleetField().frame(width: 260).accessibilityIdentifier("secret-url")
                    }
                }
                FormRow("User name") { TextField(text: $login.username, prompt: Text(verbatim: "")) { Text("User name or email") }
                    .fieldPlaceholder("User name or email", shows: login.username.isEmpty).fleetField().frame(width: 260).accessibilityIdentifier("secret-user") }
                FormRow("Password") { SecureField(text: $login.password, prompt: Text(verbatim: "")) { Text("Password") }
                    .fieldPlaceholder("Password", shows: login.password.isEmpty).fleetField().frame(width: 260).accessibilityIdentifier("secret-password") }
                // A request asks for the login alone: an authenticator's seed, if a site needs one, goes in on Secrets.
                if !isRequest {
                    if withSeed {
                        FormRow("2FA code", detail: "The authenticator's seed, or its otpauth:// address. The vault types the code at sign-in.") {
                            SecureField(text: $login.totp, prompt: Text(verbatim: "")) { Text("Seed") }
                                .fieldPlaceholder("Seed", shows: login.totp.isEmpty).fleetField().frame(width: 260).accessibilityIdentifier("secret-totp")
                        }
                    } else {
                        FormRow("2FA code", detail: "Optional.") {
                            Button("Add 2FA code") { withSeed = true }.buttonStyle(FleetOutlineButtonStyle()).accessibilityIdentifier("secret-add-totp")
                        }
                    }
                }
            } else {
                if isRequest && !preset.env.isEmpty {
                    FormRow("Variable name") {
                        Text(preset.env).font(FormMetrics.text.monospaced()).textSelection(.enabled)
                            .accessibilityIdentifier("secret-env")
                    }
                } else {
                    FormRow("Variable name", detail: "The agent's name for the key, for example OPENAI_API_KEY.") {
                        TextField(text: $login.env, prompt: Text(verbatim: "")) { Text("OPENAI_API_KEY") }
                            .fieldPlaceholder("OPENAI_API_KEY", shows: login.env.isEmpty).font(FormMetrics.text.monospaced()).fleetField().frame(width: 260)
                            .accessibilityIdentifier("secret-env")
                    }
                }
                FormRow("Key") { SecureField(text: $login.password, prompt: Text(verbatim: "")) { Text("Key") }
                    .fieldPlaceholder("Key", shows: login.password.isEmpty).fleetField().frame(width: 260).accessibilityIdentifier("secret-password") }
                if !knowsSite {
                    FormRow("Service address", detail: "Optional. With it, an agent can call the service with the key (call_api).") {
                        TextField(text: $login.url, prompt: Text(verbatim: "")) { Text("https://api.example.com") }
                            .fieldPlaceholder("https://api.example.com", shows: login.url.isEmpty).fleetField().frame(width: 260).accessibilityIdentifier("secret-url")
                    }
                }
            }
            waitRow
        }
    }

    private var footer: String {
        let shown = login.problem == nil ? "Founderizer shows it as “\(login.title)”. " : ""
        return shown + "Founderizer Vault keeps it, and gives it to the servers of the agents that get it. No agent sees it."
    }

    // MARK: who gets it

    /// What an agent's row offers: no access, use through its vault, and for an API key, read in its sessions.
    private enum Level: Hashable { case off, use, read }

    private var accessChoice: some View {
        let proposed = isRequest && !preset.give.isEmpty
        let words = login.kind == .apiKey
            ? "Uses it: its vault sends the key for it, and it never sees it. Reads it: the key is in its sessions as $\(login.variable ?? "NAME")."
            : "Its vault signs in with it. No agent sees the password."
        return FormSection(compact ? nil : "Who can use it",
                           footer: (proposed ? "\(need?.by.agentLabel ?? "The agent") proposes this. " : "") + words) {
            ForEach(holders, id: \.self) { agent in accessRow(agent) }
        }
    }

    private func accessRow(_ agent: String) -> some View {
        let name = agent.agentLabel
        let level: Level = access[agent].map { login.kind == .login || $0 == .use ? Level.use : Level.read } ?? Level.off
        var rows = [FleetOption(Level.off, "No access", mark: .symbol("slash.circle")),
                    FleetOption(Level.use, "Uses it", subtitle: "\(name) uses it and never sees it.", mark: .symbol("lock"))]
        if login.kind == .apiKey {
            rows.append(FleetOption(Level.read, "Reads it", subtitle: "The key is in its sessions. \(name) can copy it.", mark: .symbol("eye")))
        }
        let title = level == .read ? "Reads it" : level == .use ? "Uses it" : "No access"
        let mark = level == .read ? "eye" : level == .use ? "lock" : "slash.circle"
        // **The glyph in the one mark column** (`RowMark`), as on a secret's card: the name begins 50 points in, where
        // the agents' names of that card begin. A 16-point glyph and 10 of spacing put it at 42.
        return HStack(spacing: 0) {
            RowMark { AgentGlyph(name: agent, size: GlyphSize.inline) }
            Text(name).font(FormMetrics.title).foregroundStyle(FleetStyle.text)
            Spacer(minLength: 12)
            FleetSelect("Access of \(name)", options: rows, selection: level) { chosen in
                let grant: SecretGrant? = chosen == Level.read ? .read : chosen == Level.use ? .use : nil
                access[agent] = grant
            } label: {
                FleetSelectLabel(title: title, mark: .symbol(mark))
            }.accessibilityIdentifier("secret-give-\(agent)")
        }
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 8).frame(minHeight: 44)
    }

    // MARK: a request

    /// The secrets of the catalog that already fit the request: one that was saved before can answer it, so the
    /// owner does not type it twice.
    private var fits: some View {
        FormSection(compact ? nil : "In the vault already",
                    footer: "Answer with it, or save a new one below.") {
            ForEach(fitting) { found in
                FormRow("“\(found.entry.name)” is in the vault", symbol: "key", detail: found.login) {
                    Button("Answer with it") {
                        if !(onStep && SecondClick.isNow) { Task { await answerWith(found.login, entry: found.entry) } }
                    }
                        .buttonStyle(FleetOutlineButtonStyle()).disabled(busy || context == nil)
                        .accessibilityIdentifier("secret-answer-with")
                }
            }
        }
    }

    // MARK: what came of a save

    @ViewBuilder private func saved(_ progress: SecretProgress) -> some View {
        FormSection(compact ? nil : "Saved") {
            if progress.sealed != nil {
                FormRow("“\(progress.title)” is not in the vault yet", symbol: "exclamationmark.circle", detail: progress.login,
                        warning: progress.sealedProblem)
            } else {
                FormRow("“\(progress.title)” is in the vault", symbol: "checkmark.circle", detail: progress.login)
            }
            ForEach(progress.grants, id: \.agent) { grant in
                FormRow(grant.done ? Self.holds(grant) : "\(grant.agent.agentLabel) does not have it yet",
                        symbol: grant.done && !grant.warning ? "checkmark.circle" : "exclamationmark.circle",
                        detail: grant.warning ? nil : grant.note, warning: grant.warning ? grant.note : nil)
            }
            if progress.need != nil {
                FormRow(progress.answered ? "The request has its answer" : "The request is not answered yet",
                        symbol: progress.answered ? "checkmark.circle" : "exclamationmark.circle",
                        detail: progress.answered ? progress.answerNote : nil, warning: progress.answerProblem)
            }
            if let agent = progress.tell {
                FormRow(progress.told ? "\(agent.agentLabel) has its name and who holds it" : "\(agent.agentLabel) is not told yet",
                        symbol: progress.told ? "checkmark.circle" : "exclamationmark.circle", warning: progress.tellProblem)
            }
            waitRow
        }
    }

    private static func holds(_ grant: SecretProgress.Grant) -> String {
        grant.grant == .read ? "\(grant.agent.agentLabel) reads it in its sessions" : "\(grant.agent.agentLabel) can use it"
    }

    // MARK: steps

    /// The form as the preset opens it: the request's kind, name and address, and never a value.
    private static func blank(_ preset: SecretPreset) -> LoginSecret {
        var login = LoginSecret()
        login.kind = preset.kind; login.env = preset.env; login.url = preset.url
        return login
    }

    private func clear() { login = Self.blank(preset); sameName = nil; withSeed = false }

    private func text(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? "The hub did not answer." }

    /// The central vault's key, read as the form opens and at each Try again: while the hub serves the vault and names
    /// the very key this Mac pinned at Set up, the form saves there. Otherwise nothing can be saved, and the row says
    /// that the vault does not answer. What came of a save stays.
    private func start() async {
        if case .saved(_) = phase { return }
        var recipient: String?
        if features.contains(CentralVault.feature), let context,
           let reading = try? await VaultClient().reading(hub: context.hub, database: context.db), let fleet = reading.fleetID {
            recipient = reading.trusted(pin: CentralVaultPins.recipient(hub: context.hub, fleet: fleet))
        }
        if case .saved(_) = phase { return }
        central = recipient
        phase = recipient == nil ? .noVault : .form
    }

    /// The catalog's secrets that fit the request, read when a request's form opens.
    private func readFits() async {
        guard let asked = need?.secret, let context, let team = try? await client.team(hub: context.hub, database: context.db) else { return }
        fitting = (team.logins ?? [:]).filter { $0.value.isAPIKey == (asked.kind == .apiKey) && asked.fits(title: $0.value.name) }
            .sorted { $0.key < $1.key }.map { Fit(login: $0.key, entry: $0.value) }
    }

    private func save() async {
        guard !busy else { return }
        message = nil
        if let problem = login.problem { message = problem; return }
        guard let context else { message = "No current status of this hub. Nothing was sent."; return }
        guard let central else { phase = .noVault; return }
        busy = true
        defer { busy = false }
        let title = login.title, kind = login.kind, variable = login.variable, grants = chosen
        // Before anything is sent: the hub answers for this generation, and its catalog has room.
        do {
            let team = try await client.team(hub: context.hub, database: context.db)
            guard let catalog = team.logins else { message = "This hub has no list of secrets. Nothing was sent."; return }
            guard catalog.count < LoginSecret.maxCatalog else {
                message = "The list has \(LoginSecret.maxCatalog) secrets and takes no more. Nothing was sent."; return
            }
            // The entry of a central save that the hub did not confirm is this very save, not a second secret.
            if catalog.contains(where: { $0.value.name == title && $0.key != centralLogin }) && sameName != title {
                sameName = title
                message = "The list has “\(title)” already. Save again to add a second one."
                return
            }
        } catch { message = "The hub did not answer for this save. Nothing was sent. \(text(error))"; return }
        await saveCentral(to: central, context: context, title: title, kind: kind, variable: variable, grants: grants)
    }

    /// A save into the central vault. The value is sealed to the vault's key first, so it leaves the form as soon as
    /// the hub has the reference: then the sealed value, which only that vault opens, is all that is left of it here.
    /// A hub that does not confirm the reference leaves the fields as typed, and Save again goes under the same one.
    private func saveCentral(to recipient: String, context: (hub: URL, db: String), title: String, kind: LoginSecret.Kind,
                             variable: String?, grants: [SecretProgress.Grant]) async {
        guard let value = try? login.value() else { message = "This secret cannot be sent. Nothing was sent."; return }
        let sealed: String
        do { sealed = try AgeSeal.seal(value, to: recipient) }
        catch { message = "Founderizer could not seal it for the vault. Nothing was sent."; return }
        let reference = centralLogin ?? "bws://\(UUID().uuidString.lowercased())"
        centralLogin = reference
        do {
            try await Self.register(reference, title: title, kind: kind, variable: variable, value: value, hub: context.hub,
                                    database: context.db, installation: store.installation)
        } catch {
            // The hub takes no new secret while the central vault does not answer: nothing was sent.
            if case HubError.refusal(503, _) = error { central = nil; phase = .noVault; return }
            message = "The hub did not register this secret. \(text(error)) Save again to try once more."; return
        }
        clear(); centralLogin = nil
        let progress = SecretProgress(login: reference, title: title, kind: kind, grants: grants, need: preset.need, tell: preset.tell,
                                      sealed: sealed)
        phase = .saved(progress)
        await proceed(progress)
    }

    /// A secret of the catalog answers the request: the agents that the owner chose get it, then the request its answer.
    private func answerWith(_ reference: String, entry: TeamLogin) async {
        let kind: LoginSecret.Kind = entry.isAPIKey ? .apiKey : .login
        let grants = holders.compactMap { agent in access[agent].map { SecretProgress.Grant(agent: agent, grant: kind == .login ? .use : $0) } }
            + doorGrant
        clear()
        let progress = SecretProgress(login: reference, title: entry.name, kind: kind, grants: grants, need: preset.need, tell: nil)
        phase = .saved(progress)
        await proceed(progress)
    }

    /// The steps after the registration, each once: the sealed value to the central vault, the grants, each signed with
    /// the owner key first (`GrantSigning`), the answer of the request and the message to the chat's agent. A step that
    /// is done is not done again; Try again runs the rest. Nothing follows a save before the vault has its value: an
    /// agent told of a secret that is in no vault would ask for it in vain.
    private func proceed(_ start: SecretProgress) async {
        guard let context else { message = "No current status of this hub. Try again when it answers."; return }
        var progress = start
        let wasBusy = busy
        busy = true
        defer { busy = wasBusy }
        message = nil
        let secrets = SecretsClient(), installation = store.installation
        if let sealed = progress.sealed {
            do {
                _ = try await VaultClient().intake(hub: context.hub, database: context.db, client: installation, login: progress.login,
                                                   ciphertext: sealed)
                progress.sealed = nil; progress.sealedProblem = nil
                phase = .saved(progress)
            } catch {
                progress.sealedProblem = text(error)
                phase = .saved(progress)
                return
            }
        }
        for index in progress.grants.indices where !progress.grants[index].done {
            let wanted = progress.grants[index]
            do {
                try await GrantSigning.grant(wanted.grant, login: progress.login, agent: wanted.agent, store: store, hub: context.hub,
                                             database: context.db)
                let receipt = try await secrets.grant(hub: context.hub, database: context.db, client: installation, login: progress.login,
                                                      agent: wanted.agent, grant: wanted.grant)
                let note = Self.note(receipt, title: progress.title)
                progress.grants[index].done = true
                progress.grants[index].note = note?.text; progress.grants[index].warning = note?.warning ?? false
            } catch {
                progress.grants[index].note = "Not given. \(text(error))"; progress.grants[index].warning = true
            }
            phase = .saved(progress)
        }
        if let need = progress.need, !progress.answered {
            do {
                _ = try await secrets.answer(hub: context.hub, database: context.db, client: installation, need: need,
                                             requestID: progress.answerID, login: progress.login)
                progress.answered = true; progress.answerProblem = nil
            } catch {
                // A request that had its answer already, here or on another of this Mac's views of it, takes no other.
                if case HubError.refusal(409, let words) = error, words.contains("already answered") {
                    progress.answered = true; progress.answerProblem = nil; progress.answerNote = "It had an answer already."
                } else { progress.answerProblem = text(error) }
            }
            phase = .saved(progress)
        }
        if let agent = progress.tell, !progress.told {
            if await store.say(Self.telling(progress), to: agent) { progress.told = true; progress.tellProblem = nil }
            else { progress.tellProblem = store.sendError ?? "Founderizer could not send the message now. Try again." }
            phase = .saved(progress)
        }
        await store.refresh()
        // From the chat, the message under the conversation says it all: the form goes once every step is done.
        if progress.isDone && progress.tell != nil && !progress.given.contains(where: \.warning) {
            onDone(progress.login)
        }
    }

    /// The owner's message in the chat that Add secret was opened from: the secret's name and reference, who holds it
    /// and where it is. It names no value, because the app has none to name.
    static func telling(_ progress: SecretProgress) -> String {
        var words = ["I saved \(progress.kind == .apiKey ? "the API key" : "the login") \(progress.title) in the vault, as \(progress.login)."]
        let given = progress.given.map { "\($0.agent) \($0.grant == .read ? "reads it as $\(progress.title)" : "uses it through its vault")" }
        if given.isEmpty { words.append("No agent holds it yet.") }
        else { words.append((given.count == 1 ? given[0] : given.dropLast().joined(separator: ", ") + " and " + given[given.count - 1]) + ".") }
        return words.joined(separator: " ")
    }

    /// What the owner must know after a grant: the agent's vault access, or when it reads the key.
    private static func note(_ receipt: SecretGrantReceipt, title: String) -> (text: String, warning: Bool)? {
        let name = receipt.agent.agentLabel
        if let vault = receipt.vault {
            if vault.after == "broker" { return ("\(name) uses its server's vault now.", false) }
            let reasons = (vault.missing ?? []).map(VaultAccessControl.reason).joined(separator: " ")
            return ("\(name) has it, but it has no vault access yet, so it cannot use it now. \(reasons)", true)
        }
        if receipt.grant == SecretGrant.read.rawValue && receipt.changed {
            return ("\(name) reads $\(title) in its sessions from their next start.", false)
        }
        return nil
    }

    /// The owner says no to the request. The agent reads the hub's words: not given, and not to ask for it in words.
    private func decline() async {
        guard let need = preset.need, let context else { return }
        busy = true
        defer { busy = false }
        message = nil
        do {
            _ = try await SecretsClient().decline(hub: context.hub, database: context.db, client: store.installation, need: need,
                                                  requestID: declineID, words: "")
            clear()
            await store.refresh()
            onDone(nil)
        } catch {
            if case HubError.refusal(409, _) = error { declineID = UUID() }      // the request had its answer; a new one is another command
            message = "The decline did not reach the hub. \(text(error))"
        }
    }
}

extension SecretEntryView {
    /// **The hub's half of a save into the central vault**, which Add secret's form and the import of secrets from
    /// another password manager (`SecretImportView`) both make, so that there is one rule for it: the fingerprints of
    /// the value, made here from the salts that the hub gives for this reference, and the catalog entry under it. The
    /// hub takes the same reference again, so a save that it did not confirm goes under the same one. The value does
    /// not leave this call.
    static func register(_ reference: String, title: String, kind: LoginSecret.Kind, variable: String?, value: Data, hub: URL,
                         database: String, installation: String) async throws {
        let salts = try await HubClient().secretSalts(hub: hub, database: database, login: reference)
        _ = try await SecretsClient().add(hub: hub, database: database, client: installation, login: reference, title: title,
                                          kind: kind, variable: variable, fingerprints: SecretFingerprint.of(value, salts: salts))
    }
}
