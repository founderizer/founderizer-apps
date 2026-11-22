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
    /// **The key page of an agent on a key or a model server** (the AI providers build, picture 3, his "Yes, as
    /// shown"): the vault's own form on a step, its Key field and Save alone, for a new key of this variable name
    /// and site, which no agent holds yet. The add gives the new agent its grant after the agent exists.
    var keyStep = false
    /// **The note that the request gives the secret** (owner feature `secret_notes`): the form shows it as a field that
    /// the owner can change, only when the request has one.
    var note = ""
    /// The account that a login request names: the start of the form's User name field.
    var account = ""
    /// **The reference of a key of the list whose value this form replaces, in one press** (`SecretValueReplace`): the
    /// part "Value" of the key's card, and a request for a new value of a key that the fleet holds. Save says Replace,
    /// and the save puts the new value under this reference with no access step: the same agents keep the key.
    var replace: String?
    /// **The part "Value" of a key's card** (`SecretsPage.detail`; the owner's "Yes, both" of 21 November 2026): one
    /// secure field, Cancel and Replace, and the muted line under them.
    var valuePart = false
    /// **Save a secret over the window keeps its form here** (`SecretValueKept`): `fleetModal` builds its card two times.
    /// Nil for every other form, which keeps its own state.
    var kept: SecretValueKept?

    /// The preset of a key page: the variable name and the key's site, which the page sets under the hood.
    static func keyStep(variable: String, site: String) -> SecretPreset {
        var preset = SecretPreset()
        preset.kind = .apiKey; preset.env = variable; preset.url = site; preset.keyStep = true
        return preset
    }

    /// The preset of the part "Value" of a key's card: the key of this reference, by its variable name.
    static func value(of reference: String, entry: TeamLogin) -> SecretPreset {
        var preset = SecretPreset()
        preset.kind = .apiKey; preset.env = entry.env ?? entry.name; preset.replace = reference; preset.valuePart = true
        return preset
    }

    init(tell: String? = nil, key: String? = nil, give: [String: SecretGrant] = [:], kept: SecretValueKept? = nil) {
        self.tell = tell; self.key = key; self.give = give; self.kept = kept
    }

    init(need: OwnerNeed) {
        let asked = need.secret ?? NeedSecret(kind: .apiKey)
        self.need = need.id
        // a request for a new value takes no address: it would take the place of the key's own (`formAddress`)
        kind = asked.kind; env = asked.env ?? ""; url = SecretValueReplace.formAddress(asked); give = asked.give
        note = asked.note ?? ""; account = asked.kind == .login ? asked.account ?? "" : ""
        // a request for a new value of a key that the fleet holds: Replace, under that key's own reference
        replace = asked.replaces
    }
}

/// What came of a save once the central vault had it, step by step: who got it, the request that it answers and the
/// chat that it tells. Nothing in it is a value: the sealed value opens only in the central vault.
struct SecretProgress: Equatable {
    struct Grant: Equatable {
        let agent: String
        /// The level that the agent gets; nil takes the secret back from it (a replace, where an agent had it).
        let grant: SecretGrant?
        var done = false
        /// What the owner must know about this agent's access, or why it is not given.
        var note: String?
        var warning = false
    }
    let login: String
    let title: String
    let kind: LoginSecret.Kind
    var grants: [Grant]
    /// The form's own request, or nil.
    let need: Int?
    /// **The requests that the save answers** (`SecretValueReplace.answers`): its own first, then, for a new value of a
    /// key of the list, each other open request for a new value of that key.
    let needs: [Int]
    /// The one answer of each request, so that a retry is that answer again and never a second one.
    let answerIDs: [Int: UUID]
    var answeredNeeds: Set<Int> = []
    var answered: Bool { needs.allSatisfy(answeredNeeds.contains) }
    /// The hub's words when the form's own request had its answer already.
    var answerNote: String?
    var answerProblem: String?
    /// The secret's note as the form showed it at the save, which goes with the request's answer; nil where the form
    /// showed no note, and for an answer with a secret of the list that the note does not go to (`NeedSecret.noteGoes`).
    var note: String? = nil
    let tell: String?
    var told = false
    var tellProblem: String?
    /// A save into the central vault: the value sealed to its key, until the vault has it. Only that vault opens it,
    /// and nothing after it runs before it is there.
    var sealed: String?
    var sealedProblem: String?
    /// A replace of the value of a key that the list has (owner feature `secret_replace`): the owner's signed
    /// statement about the sealed copy, which goes to the vault with it. Neither is a value.
    var statement: String?
    var signature: String?
    var replaces: Bool { statement != nil }

    var isDone: Bool {
        sealed == nil && grants.allSatisfy(\.done) && answered && (tell == nil || told)
    }
    var given: [Grant] { grants.filter(\.done) }

    init(login: String, title: String, kind: LoginSecret.Kind, grants: [Grant], need: Int?, needs: [Int]? = nil, note: String? = nil,
         tell: String?, sealed: String? = nil, statement: String? = nil, signature: String? = nil) {
        self.login = login; self.title = title; self.kind = kind; self.grants = grants; self.need = need
        let all = needs ?? need.map { [$0] } ?? []
        self.needs = all; answerIDs = Dictionary(all.map { ($0, UUID()) }, uniquingKeysWith: { first, _ in first })
        self.note = note; self.tell = tell; self.sealed = sealed; self.statement = statement; self.signature = signature
    }
}

/// **What a key's form holds in a card that `fleetModal` builds two times, outside the views that draw it** (Fable's
/// reviews of 21 and 22 November 2026): `fleetModal` builds a card that is as high as its content two times, as it is
/// and inside a scroll, and shows the one that fits (`FleetModalCard`). A form's state is one build's, so a card that
/// grew past the window showed the other build: the typed value, the save's ring and its orange line were gone, and
/// after Manage the rows were closed again, with an empty Key field. The card's own item holds this, and both builds
/// draw from it, so they show one form and one save, and a save that one build started writes here when the other one
/// shows. The places: the part "Value" of a key's card (`SecretCard`), Save a secret over the window
/// (`SecretPreset.kept`) and a key request in a job's card (`FleetStore.keptKeyForm`). It goes with the card: memory
/// only, never on the disk, and the value is cleared once the hub has the reference, as the form's own is.
@MainActor @Observable final class SecretValueKept {
    fileprivate var phase: SecretEntryView.Phase?
    fileprivate var login: LoginSecret?
    fileprivate var message: String?
    fileprivate var busy = false
    fileprivate var saving = false
    fileprivate var central: String?
    fileprivate var mark = KeyValueMark()
    /// The rest of the form: Manage, the rows, the note, his words about the request (`SecretFormDraft`).
    fileprivate var draft: SecretFormDraft?
}

/// **The form's choices and words**, which a form keeps in its own state, or in its card's item (`SecretValueKept`):
/// none of them is a value. Each one is told where `SecretEntryView` reads it.
fileprivate struct SecretFormDraft {
    var access: [String: SecretGrant]
    var managing = false
    var touched: Set<String> = []
    var proposed: Set<String>
    var levelsOf: String?
    var levelsEntry: TeamLogin?
    var raised: [String: SecretGrant] = [:]
    var withSeed = false
    var sameName: String?
    var secretNote: String
    var noteOpened = false
    var centralLogin: String?
    var clarifying: Bool
    var clarifyText: String
    var sendingWords = false
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
/// **The list takes no second API key of one variable name** (the owner, 13 November 2026: "having 2 keys named the
/// same should not be possible"). When the list has one key of that name, Save puts the new value under that key's
/// own reference (owner feature `secret_replace`): the form registers the new fingerprints under it, and sends the
/// sealed copy with the owner's signed statement about that copy, which is what lets the central vault put a new value
/// in the place of the old one. The same agents keep the key, and its site stays. The orange line says so before the
/// Save that does it (`SameName`). When the list has two keys of that name from before, or the vault cannot replace a
/// value yet, the line says that and Save sends nothing. A login with a title that the list has is as before.
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
    /// **A request's card in a chat, and the request at hand on Needs you, draw his save** (`KeySaveLook`): a ring while
    /// it runs, then a check, and they keep the form's parts out of sight meanwhile. Nil where nothing draws it (Add
    /// secret, a key page).
    private let onLook: ((KeySaveLook?) -> Void)?

    /// The hub features of Add secret and its grants. Show the Add button only with them.
    static let feature = "secrets"
    static func isOffered(by store: FleetStore) -> Bool {
        let features = store.state?.ui_features ?? []
        return features.contains(feature) && features.contains("secret_grants")
    }

    fileprivate enum Phase: Equatable { case form, noVault, saved(SecretProgress) }

    /// **The words of Add secret for a name that the list has**, each one once and in this one place. The owner said
    /// yes to `replaces`, and then to `twice`, `notYet`, `notInVault` and `told` in these exact forms ("Yes, all
    /// four", 13 November 2026). They are new words in elements that he has. `second` is the line from before.
    enum SameName {
        /// The orange line: one API key of that variable name. The next Save puts the new value under it.
        static func replaces(_ name: String) -> String { String(l10n: "The list has “\(name)” already. Save replaces its key: the same agents keep it.") }
        /// The orange line: two keys of that name, from before the list refused a second one. Save sends nothing.
        static func twice(_ name: String) -> String { String(l10n: "The list has “\(name)” two times. Remove one first.") }
        /// The orange line: the central vault's program does not replace a value yet. Save sends nothing.
        static func notYet(_ name: String) -> String { String(l10n: "Founderizer Vault cannot replace “\(name)” yet. Try again in a few minutes.") }
        /// The orange line: a login of that title. A second one, as before.
        static func second(_ name: String) -> String { String(l10n: "The list has “\(name)” already. Save again to add a second one.") }
        /// The first row of what came of a save, while the new value of a replace is not in the vault.
        static func notInVault(_ name: String) -> String { String(l10n: "The new key of “\(name)” is not in the vault yet") }
        /// The rows of what came of a save, for an agent that the owner took the key back from in a replace: after
        /// the step, while it is not done, and the note of a step that failed.
        static func tookBack(_ agent: String) -> String { String(l10n: "\(agent) has no access") }
        static func notTakenBack(_ agent: String) -> String { String(l10n: "\(agent) still has it") }
        static let takeBackFailed = String(l10n: "Not taken back.")
        /// The owner's message to the chat's agent after a replace: never "No agent holds it yet." It names no
        /// reference: the key keeps the one that its holders know, and the owner reads this bubble.
        static func told(_ name: String) -> String {
            "I replaced the value of the API key \(name) in the vault. The agents that hold it keep it."
        }
    }
    /// The detail of the row "Founderizer Vault does not answer" while the central vault does not answer: new words
    /// in an existing row, which wait for the owner's yes (AGENTS.md).
    static let noVaultDetail: String? = String(l10n: "Nothing was sent. Try again in a moment.")
    @State private var ownPhase: Phase
    @State private var ownLogin: LoginSecret
    /// **A card that `fleetModal` builds two times keeps these in its item** (`SecretValueKept`): the form's step, the
    /// typed value, the orange line, the save's run, the vault's key, the mark and the rest of the form (`draft`).
    /// Every other form keeps them in its own state.
    private let kept: SecretValueKept?
    @State private var ownDraft: SecretFormDraft
    private var draft: SecretFormDraft {
        get { kept?.draft ?? ownDraft }
        nonmutating set { if let kept { kept.draft = newValue } else { ownDraft = newValue } }
    }
    private var phase: Phase {
        get { kept?.phase ?? ownPhase }
        nonmutating set { if let kept { kept.phase = newValue } else { ownPhase = newValue } }
    }
    private var login: LoginSecret {
        get { kept?.login ?? ownLogin }
        nonmutating set { if let kept { kept.login = newValue } else { ownLogin = newValue } }
    }
    /// The fields' binding of `login`.
    private var loginField: Binding<LoginSecret> { Binding(get: { login }, set: { login = $0 }) }
    /// The access that each agent gets, by name. An agent that is not in it gets none.
    private var access: [String: SecretGrant] { get { draft.access } nonmutating set { draft.access = newValue } }
    /// **Manage opened the row of each agent** (`accessChoice`): they stay open while the form stands.
    private var managing: Bool { get { draft.managing } nonmutating set { draft.managing = newValue } }
    /// The agents whose row the owner set himself in this form. A replace shows each other agent's level of now, and
    /// only a row that he set, or that a request proposes, makes a step (`SecretReplaceAccess`).
    private var touched: Set<String> { get { draft.touched } nonmutating set { draft.touched = newValue } }
    /// The agents whose row is the request's proposal, until the owner changes it himself.
    private var proposed: Set<String> { get { draft.proposed } nonmutating set { draft.proposed = newValue } }
    /// The reference of the key whose levels of now the rows show, from the Save that found it; nil while they show
    /// none. A change of the name takes those levels out of the rows again.
    private var levelsOf: String? { get { draft.levelsOf } nonmutating set { draft.levelsOf = newValue } }
    /// That key's entry as the Save read it, and his own pick for each row of his that shows a higher level than he
    /// picked (`SecretReplaceAccess.rows`): the pick comes back when the name names that key no more.
    private var levelsEntry: TeamLogin? { get { draft.levelsEntry } nonmutating set { draft.levelsEntry = newValue } }
    private var raised: [String: SecretGrant] { get { draft.raised } nonmutating set { draft.raised = newValue } }
    /// The authenticator seed field shows.
    private var withSeed: Bool { get { draft.withSeed } nonmutating set { draft.withSeed = newValue } }
    /// The last problem or the next step, in orange.
    @State private var ownMessage: String?
    private var message: String? {
        get { kept.map(\.message) ?? ownMessage }
        nonmutating set { if let kept { kept.message = newValue } else { ownMessage = newValue } }
    }
    @State private var ownBusy = false
    private var busy: Bool {
        get { kept?.busy ?? ownBusy }
        nonmutating set { if let kept { kept.busy = newValue } else { ownBusy = newValue } }
    }
    /// His save, or his answer with a key of the list, passed the checks that end with a line of their own and has not
    /// ended (`KeySaveLook.of`).
    @State private var ownSaving = false
    private var saving: Bool {
        get { kept?.saving ?? ownSaving }
        nonmutating set { if let kept { kept.saving = newValue } else { ownSaving = newValue } }
    }
    /// The owner saw that the catalog has this name (the orange line of `SameName`) and pressed Save again.
    private var sameName: String? { get { draft.sameName } nonmutating set { draft.sameName = newValue } }
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
    /// **The secret's note**, which the request gave: the field's words (`showsNote`).
    private var secretNote: String { get { draft.secretNote } nonmutating set { draft.secretNote = newValue } }
    private var noteWordsField: Binding<String> { Binding(get: { secretNote }, set: { secretNote = $0 }) }
    /// **Needs clarification** (owner feature `secret_clarify`; the owner, 19 November 2026: "There should be a way to
    /// Reply or comment to the card, to give more context or clarify something", then "I prefer Needs clarification",
    /// and "THEN show the text input"): its link opened the field, and the words that he writes about the request.
    /// They close the request and go to the agent that asked, which asks again.
    private var clarifying: Bool { get { draft.clarifying } nonmutating set { draft.clarifying = newValue } }
    private var clarifyText: String { get { draft.clarifyText } nonmutating set { draft.clarifyText = newValue } }
    @State private var clarifyID = UUID()
    @FocusState private var clarifyFocused: Bool
    /// He pressed the link now: the field takes the cursor once it stands. Words that come back from memory do not
    /// take it: a field that takes the cursor selects its words, and his next key would take their place.
    @State private var cursorToWords = false
    /// His words go to the hub: the wait says "Sending…", where a save says "Saving…".
    private var sendingWords: Bool { get { draft.sendingWords } nonmutating set { draft.sendingWords = newValue } }
    /// **The words that he wrote and did not send, by the request, in memory only**: the request at hand is a new view
    /// each time it comes to hand, and words that he wrote there were gone after a click on another card. They are
    /// never written to a file, as the drafts of an answer are (`FleetStore.answers`), because a key that he pasted
    /// here by mistake must not stay on the disk; words that look like a key are not kept at all, and words that hold
    /// the value of the form's own field are not kept from their next change on. The key is the hub, its generation
    /// and the request (`draftKey`), and the words go
    /// when the request closes in any way (`forgetDraft`) and when the list of open requests no longer has it.
    @MainActor private static var clarifyDrafts: [String: String] = [:]
    private static func draftKey(hub: URL, database: String?, need: Int) -> String { "\(hub.absoluteString) \(database ?? "") \(need)" }
    private var draftKey: String? { preset.need.map { Self.draftKey(hub: hub, database: database, need: $0) } }
    private func forgetDraft() { if let draftKey { Self.clarifyDrafts[draftKey] = nil } }
    @Environment(\.colorSchemeContrast) private var contrast
    /// The hub address and the generation when this form opened. A later connection change in the store ends its use.
    @State private var hub: URL
    @State private var database: String?
    private let client = HubClient()
    /// The central vault's key, which the form seals to, read as it opens and at each Try again; nil while it is not
    /// known, and Save waits for it.
    @State private var ownCentral: String?
    private var central: String? {
        get { kept.map(\.central) ?? ownCentral }
        nonmutating set { if let kept { kept.central = newValue } else { ownCentral = newValue } }
    }
    /// The reference of a central save that the hub did not confirm: the same Save again goes under it, so a save that
    /// did reach the catalog is not added twice. Any change of the fields drops it.
    private var centralLogin: String? { get { draft.centralLogin } nonmutating set { draft.centralLogin = newValue } }
    /// The form stands under the title of a step: the request at hand on Needs you (`NeedStep`).
    @Environment(\.stepText) private var stepText

    /// A key page's line from the add after the save (the hub's refusal of the account or of the agent, round 2
    /// sentences 4, 6, 7 and 8), and its Save again, which goes on with the key that the vault has already: the form's
    /// one orange line and its one button, so the page keeps its look.
    private let note: String?
    private let again: (() -> Void)?

    /// `kept`: the state of a form whose card `fleetModal` builds two times, which its card's item keeps
    /// (`SecretValueKept`).
    init(store: FleetStore, preset: SecretPreset = SecretPreset(), compact: Bool = false, note: String? = nil,
         again: (() -> Void)? = nil, onLook: ((KeySaveLook?) -> Void)? = nil, kept: SecretValueKept? = nil,
         onDone: @escaping (String?) -> Void) {
        self.store = store; self.preset = preset; self.compact = compact; self.onDone = onDone
        self.note = note; self.again = again; self.onLook = onLook; self.kept = kept
        _hub = State(initialValue: store.hub); _database = State(initialValue: store.state?.db)
        // The form shows at once and waits for the central vault's key before Save; a hub without it shows the row.
        _ownPhase = State(initialValue: store.state?.ui_features?.contains(CentralVault.feature) == true ? .form : .noVault)
        var login = Self.blank(preset)
        if let key = preset.key { login.password = key }
        _ownLogin = State(initialValue: login)
        // The words of requests of this hub that are no longer open go: nothing shows them again.
        let open = Set((store.state?.needs ?? []).filter(\.isOpen).map { Self.draftKey(hub: store.hub, database: store.state?.db, need: $0.id) })
        let here = "\(store.hub.absoluteString) \(store.state?.db ?? "") "
        Self.clarifyDrafts = Self.clarifyDrafts.filter { !$0.key.hasPrefix(here) || open.contains($0.key) }
        let words = preset.need.flatMap { Self.clarifyDrafts[Self.draftKey(hub: store.hub, database: store.state?.db, need: $0)] } ?? ""
        _ownDraft = State(initialValue: SecretFormDraft(access: preset.give, proposed: Set(preset.give.keys),
                                                        secretNote: NeedSecret.oneLine(preset.note, most: NeedSecret.noteMost),
                                                        clarifying: !words.isEmpty, clarifyText: words))
    }

    /// The hub and the generation of this view, while the store still shows them and its reading is current.
    private var context: (hub: URL, db: String)? {
        guard let database, store.hub == hub, store.state?.db == database, store.writesNow, Self.isOffered(by: store) else { return nil }
        return (hub, database)
    }

    private var features: [String] { store.state?.ui_features ?? [] }
    private var isRequest: Bool { preset.need != nil }
    /// The form shows the note's field: the request gave a note, and the hub keeps one (`secret_notes`). A request
    /// with no note has no such field: an agent writes a note where a name does not say which account it is.
    private var showsNote: Bool { isRequest && !preset.note.isEmpty && features.contains("secret_notes") }
    /// **The note's field shows only while the card's Details are open** (the owner, 21 November 2026: "Note should
    /// also be hidden by default, unless Details are expanded"; `requestNoteShows`). Hidden, the note is still the
    /// request's, and goes with the save as before.
    @Environment(\.requestNoteShows) private var noteShows
    /// **A save that stopped on the note opens its field** (Fable's review of 22 November 2026): a request with a note,
    /// no details and a short reason has no Details link, and Save stopped with a line about a field that he could not
    /// open. From the line on, the field shows while the form stands, also with Details closed, so it does not go away
    /// under his cursor once the note holds no key. By default it stays hidden, as the owner said.
    private var noteOpened: Bool { get { draft.noteOpened } nonmutating set { draft.noteOpened = newValue } }
    private var noteField: Bool { showsNote && (noteShows || noteOpened || message == Self.keyInNote) }
    /// The note as it goes to the hub: one line of the hub's most, counted as the hub counts (`NeedSecret.oneLine`).
    private var noteWords: String { NeedSecret.oneLine(secretNote, most: NeedSecret.noteMost) }
    /// The request takes his words about it (`secret_clarify`).
    private var clarifies: Bool { isRequest && features.contains("secret_clarify") }
    private var clarifyWords: String { clarifyText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canClarify: Bool {
        !busy && context != nil && !clarifyWords.isEmpty && NeedSecret.length(clarifyWords) <= NeedSecret.clarifyMost
    }
    /// The orange line for words that look like a key, or that hold the value of the form's own field (`holdsKey`):
    /// they are not sent, and they stay in the field for him to change. True also while the form shows no field (the
    /// vault does not answer).
    static let keyInWords = String(l10n: "That looks like a key. Never send a key in a message.")
    /// The orange line for a note that looks like it holds a key: the note is no secret, and each agent that holds
    /// the secret reads it.
    static let keyInNote = String(l10n: "The note looks like it holds a key. A note is never a key.")
    /// His words hold what looks like a key, or the very value that the form's Key or Password field holds now, as a
    /// word of its own and when it has 8 characters or more (`NeedSecret.holds`).
    private func holdsKey(_ words: String) -> Bool {
        KeyInText.contains(words) || NeedSecret.holds(value: login.password, in: words)
    }
    /// A request's form on a step: what it draws stands in the middle, as a step's field and its button do.
    private var onStep: Bool { stepText != nil && (isRequest || preset.keyStep) }
    /// **On a step, a request that names all but the value is the fields for the value alone** (the owner's yes of 11
    /// November 2026 to the picture of a request at hand: a Key field, Save, Decline): its site, and for a key its
    /// variable, stand in the request's own title. Any other request keeps the rows of its card there.
    /// A request for a new value of a key (`replace`) names its key in its title: its Key field alone, and the note.
    private var fieldsAlone: Bool {
        onStep && (knowsSite && (login.kind == .login || !preset.env.isEmpty) || preset.replace != nil) || preset.keyStep
    }
    /// Save can go: the vault's key is known, and what he typed is a login or a key.
    private var canSave: Bool { !busy && central != nil && login.problem == nil && context != nil }
    /// A request that names its site keeps it: the card's title already says the host, so the form asks for no address.
    private var knowsSite: Bool { (isRequest || preset.keyStep) && !preset.url.isEmpty }
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

    /// **What the request's card in a chat, or the request at hand on Needs you, draws for this form** (`KeySaveLook`),
    /// only where one draws it. The form draws all its parts as before: while its place shows the ring or the check, it
    /// keeps them out of sight (`KeptAway`), so one change of that place moves it all, closed and open again.
    private var cardLook: KeySaveLook? {
        guard onLook != nil, compact, isRequest else { return nil }
        if case .saved(let progress) = phase {
            // a grant whose agent cannot use the key yet, or an answer that the request had already: rows, never a check
            let warned = progress.given.contains(where: \.warning) || progress.answerNote != nil
            return KeySaveLook.of(done: progress.isDone, warned: warned, busy: busy, saving: saving)
        }
        return KeySaveLook.of(done: nil, busy: busy, saving: saving)
    }

    var body: some View {
        VStack(alignment: onStep ? .center : .leading, spacing: 14) {
            switch phase {
            // **An error is its line and one sentence, with no footer that explains** (fix round 3, item 35).
            case .noVault:
                FormSection(compact ? nil : String(l10n: "Add secret")) {
                    FormRow("Founderizer Vault does not answer", detail: Self.noVaultDetail) {
                        Button("Try again") { Task { await start() } }.buttonStyle(FleetOutlineButtonStyle()).disabled(busy)
                            .accessibilityIdentifier("secret-vault-retry")
                    }
                }
            // **The part "Value" at rest, while its Replace runs and as its check draws**: one case of two patterns, so it
            // is one view through his whole Replace (Fable's review of 22 November 2026). As two cases, SwiftUI made a
            // new view at each change between .form and .saved: the ring started again, and the check drew itself a
            // second time. The mark stands at the start of its row (`KeyValueMark`); the form's rows only for a step
            // that failed.
            case .form where preset.valuePart, .saved where preset.valuePart && valueLook != .failed: valueForm
            case .form:
                // **A request for a new value of a key that the fleet holds** (`replace`) has no secret of the list to
                // answer with, and no "Who can use it": the same agents keep the key.
                if !fitting.isEmpty && preset.replace == nil { fits }
                form
                if !holders.isEmpty && !forOneAgent && !preset.keyStep && preset.replace == nil { accessChoice.disabled(busy) }
            // A key page goes on by itself once the vault has the key: until then its field and its moving words.
            // **While the vault takes the key: "Saving…" and no button** (review M3); a failed intake is the form's one
            // orange line, with Save again for the same reference.
            case .saved where preset.keyStep:
                stepField(String(l10n: "Key"), text: .constant(""), secure: true, id: "secret-password").disabled(true)
                // In the middle, as the field's own wait stands (`stepFields`).
                waitRow.fixedSize()
            case .saved(let progress): saved(progress)
            }
            if let message = message ?? keyStepProblem ?? (busy ? nil : note) {
                Text(message).font(FormMetrics.onStep(onStep ? stepText : nil) ?? FormMetrics.detail).foregroundStyle(.orange)
                    .multilineTextAlignment(onStep ? .center : .leading).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled).accessibilityIdentifier("secret-message")
            }
            if preset.valuePart {
                // The part's own row is in its form; Try again and Done only under the rows of a step that failed.
                if valueLook == .failed { actions }
            } else if onStep { stepActions } else { actions }
        }
        // **The form's width** (margins row 26): Add secret's cards take the 680 points of every form page's cards, as a
        // secret request's form does in its card in a chat. It stood 560, 120 points short of the cards beside it.
        // Under a request at hand it stands in the middle of the step, as its title does.
        .frame(maxWidth: FormMetrics.formWidth, alignment: onStep ? .center : .leading)
        .task { await start() }
        .task(id: preset.need) { await readFits() }
        // A form that goes ends what its card drew for it: a save that ran on is the reading's to show. The part
        // "Value" keeps its value in its card's item, which goes with the card: one of its two builds goes when the
        // other shows, and the value stays for that one (`SecretValueKept`).
        .onDisappear { if kept == nil { clear() }; onLook?(nil) }
        // Each change of the look, and the look of the moment the form comes: nil, for its fields.
        .onChange(of: cardLook, initial: true) { _, look in onLook?(look) }
        .onChange(of: valueLook, initial: true) { _, look in mark { $0.take(look) } }
    }

    @ViewBuilder private var actions: some View {
        if clarifying, phase == .form || phase == .noVault { clarifyBox }
        if clarifies, !clarifying, phase == .form || phase == .noVault {
            // **Needs clarification, in a card: a button of the row's own look at its leading edge**, which opens the
            // field. **Where the row does not fit, it stands on a line of its own over the answers** (Fable's review of
            // 22 November 2026): a card's own window is 340 points at the least, a button's words never wrap, Replace is
            // wider than Save, and Spanish is wider still. The answers keep their place at the trailing edge.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { clarifyButton; Spacer(); answerButtons }
                VStack(alignment: .leading, spacing: 8) {
                    clarifyButton
                    HStack(spacing: 8) { Spacer(minLength: 0); answerButtons }
                }
            }
        } else {
            HStack(spacing: 8) { Spacer(); answerButtons }
        }
    }

    private var clarifyButton: some View {
        Button("Needs clarification") { clarifying = true; cursorToWords = true }.buttonStyle(FleetOutlineButtonStyle())
            .disabled(busy || context == nil)
            .help("Write to \(need?.by.agentLabel ?? String(l10n: "the agent")) about this request").accessibilityIdentifier("secret-clarify")
    }

    /// The answers at the trailing edge of the row: after a save, Try again and Done; else Decline or Cancel, and Save.
    @ViewBuilder private var answerButtons: some View {
        if case .saved(let progress) = phase {
            if !progress.isDone {
                Button("Try again") { Task { await proceed(progress) } }.buttonStyle(FleetOutlineButtonStyle())
                    .disabled(busy || context == nil).accessibilityIdentifier("secret-retry")
            }
            Button("Done") {
                // the part "Value" is at rest again, with its field: what failed is said, and Replace can go again
                if preset.valuePart { phase = .form; message = nil }
                onDone(progress.login)
            }.buttonStyle(FleetPrimaryButtonStyle()).disabled(busy)
                .keyboardShortcut(.defaultAction).accessibilityIdentifier("secret-done-saving")
        } else {
            if isRequest {
                Button("Decline") { Task { await decline() } }.buttonStyle(FleetOutlineButtonStyle())
                    .disabled(busy || context == nil)
                    .help("Tell \(need?.by.agentLabel ?? String(l10n: "the agent")) that you do not give it").accessibilityIdentifier("secret-decline")
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

    private var saveLabel: String {
        if preset.replace != nil { return String(l10n: "Replace") }
        return preset.tell.map { String(l10n: "Save and tell \($0.agentLabel)") } ?? String(l10n: "Save")
    }

    /// **The same actions under a request at hand, in the middle** (`onStep`): Decline and Save in one row, Save the
    /// step's one white button, and the quiet link Needs clarification under them; after a save, Try again and Done.
    /// Why the intake of a key page's key failed, once nothing runs (review M3).
    private var keyStepProblem: String? {
        guard preset.keyStep, !busy, case .saved(let progress) = phase else { return nil }
        return progress.sealedProblem
    }

    @ViewBuilder private var stepActions: some View {
        if case .saved(let progress) = phase, preset.keyStep {
            // A key page has no Done and no Try again: Save again sends the same sealed key under the same reference,
            // and the page goes on by itself once the vault has it.
            if !busy && !progress.isDone {
                Button(saveLabel) { if !SecondClick.isNow { Task { await proceed(progress) } } }.buttonStyle(FleetPrimaryButtonStyle())
                    .accessibilityIdentifier("secret-save")
            }
        } else if case .saved(let progress) = phase {
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
                // **Decline and Save in one row** (the owner, 19 November 2026, of Decline as a link under Save: "show
                // Save and decline in the same row to save space"): Decline in the outline of every second button,
                // then Save, the step's one white button.
                HStack(spacing: 10) {
                    if isRequest {
                        Button("Decline") { if !SecondClick.isNow { Task { await decline() } } }.buttonStyle(FleetOutlineButtonStyle())
                            .disabled(busy || context == nil)
                            .help("Tell \(need?.by.agentLabel ?? String(l10n: "the agent")) that you do not give it").accessibilityIdentifier("secret-decline")
                    }
                    // The second click of a double-click on the request before this one presses nothing here (`SecondClick`).
                    if phase == .form, let again {
                        // The key is in the vault already: Save goes on with it.
                        Button(saveLabel) { if !SecondClick.isNow { again() } }.buttonStyle(FleetPrimaryButtonStyle())
                            .disabled(busy).accessibilityIdentifier("secret-save")
                    } else if phase == .form {
                        Button(saveLabel) { if !SecondClick.isNow { Task { await save() } } }.buttonStyle(FleetPrimaryButtonStyle())
                            .disabled(!canSave).accessibilityIdentifier("secret-save")
                    }
                }
                // **Needs clarification**, the quiet link under the row, and then the field in its place.
                if clarifies {
                    if clarifying {
                        clarifyBox.frame(maxWidth: SetupMetrics.field)
                    } else {
                        SetupLink(String(l10n: "Needs clarification")) { if !SecondClick.isNow { clarifying = true; cursorToWords = true } }
                            .disabled(busy || context == nil)
                            .help("Write to \(need?.by.agentLabel ?? String(l10n: "the agent")) about this request").accessibilityIdentifier("secret-clarify")
                    }
                }
            }
        }
    }

    /// **The field of Needs clarification**: the box of a request's answer (`NeedAnswerBox`), with no files and no
    /// replies: one line at rest and a line more for each line he writes, Send with Return. Words that look like a key
    /// are not sent: the form's orange line says so (`keyInWords`).
    private var clarifyBox: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(String(l10n: "Message to \(need?.by.agentLabel ?? String(l10n: "the agent"))"), text: Binding(get: { clarifyText }, set: { clarifyText = $0 }), axis: .vertical)
                .focused($clarifyFocused)
                .accessibilityIdentifier("secret-clarify-words")
                .onKeyPress(keys: [.return], phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    if canClarify { Task { await clarify() } }
                    return .handled
                }
                .composerField(alone: true, lines: 1...8, font: onStep ? SetupMetrics.textFont : ChatStyle.font,
                               line: onStep ? 18 : ChatStyle.line)
                .onChange(of: clarifyText) { old, now in
                    if NeedSecret.length(now) > NeedSecret.clarifyMost {
                        // A change that makes the words one character longer than they were, and too long, does not
                        // go in: a typed character, anywhere in the words. Any other change that is too long is cut
                        // at the end of the words.
                        clarifyText = now.count == old.count + 1 && NeedSecret.length(old) <= NeedSecret.clarifyMost
                            ? old : NeedSecret.cut(now, most: NeedSecret.clarifyMost)
                        return
                    }
                    if message == Self.keyInWords, !holdsKey(now) { message = nil }
                    // kept for the next time this request comes to hand; never words that look like a key
                    let kept = now.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let draftKey { Self.clarifyDrafts[draftKey] = holdsKey(now) || kept.isEmpty ? nil : now }
                }
            SendSlot(shows: canClarify) {
                // Not from the second click of a double-click on the request before this one (`SecondClick`): words
                // that he left here stand with Send from the frame this request comes to hand.
                Button { if !(onStep && SecondClick.isNow) { Task { await clarify() } } } label: { SendMark() }
                    .buttonStyle(FleetIconButtonStyle(filled: true)).disabled(!canClarify)
                    .help("Send this message").accessibilityLabel("Send message")
                    .accessibilityIdentifier("secret-clarify-send")
            }
        }
        // On a step the box at rest is as high as the fields over it (`SetupMetrics.fieldHeight`), in their width; in
        // a card it has the room of the composer.
        .padding(.vertical, onStep ? max(0, (SetupMetrics.fieldHeight - IconMetrics.side) / 2) : ComposerCapsule<EmptyView, EmptyView>.inset)
        // (its words begin where the words of those fields begin, and Send has the same room at each side)
        .padding(.leading, onStep ? 6 : ComposerCapsule<EmptyView, EmptyView>.inset)
        .padding(.trailing, onStep ? 3 : ComposerCapsule<EmptyView, EmptyView>.inset)
        .background(FleetStyle.composer, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
        .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner)
            .strokeBorder(FleetStyle.hairline(0.32), lineWidth: FleetStyle.edgeWidth(contrast)))
        .contentShape(RoundedRectangle(cornerRadius: FormMetrics.inner))
        .onTapGesture { clarifyFocused = true }
        .disabled(busy)
        // The cursor comes once the field stands, as the answer box takes it (`NeedAnswerBox`): set in the press that
        // makes the field, it could stay where it was, and Return in a chat then sent the chat's own message.
        .task { if cursorToWords { clarifyFocused = true; cursorToWords = false } }
    }

    // MARK: the part "Value"

    /// **What the part "Value" draws for his Replace** (`KeySaveLook`): the ring while it runs, the check once every step
    /// is done, `failed` for a step that failed after the value went in; nil at rest, and for every other form.
    private var valueLook: KeySaveLook? {
        guard preset.valuePart else { return nil }
        if case .saved(let progress) = phase { return KeySaveLook.of(done: progress.isDone, busy: busy, saving: saving) }
        return KeySaveLook.of(done: nil, busy: busy, saving: saving)
    }

    @State private var ownMark = KeyValueMark()
    /// The mark at the start of the part's row (`KeyValueMark`), in its card's item.
    private var valueMark: KeySaveLook? { kept?.mark.look ?? ownMark.look }
    /// A change of the mark, in the key save's one short motion. **VoiceOver says "Saved" as the check comes**, as on a
    /// key card (`NeedRequestCard.took`): Replace, which had the focus, is disabled while the save runs, and nothing
    /// else said that the save ended. Once for each Replace (`KeyValueMark`), also with the card's two builds, which
    /// share the mark (`SecretValueKept`).
    private func mark(_ change: (inout KeyValueMark) -> Void) {
        let now = kept?.mark ?? ownMark
        var next = now
        change(&next)
        guard next != now else { return }
        withAnimation(reduceMotion ? nil : FleetMotion.keySave) { if let kept { kept.mark = next } else { ownMark = next } }
        if next.look == .saved && now.look != .saved { AccessibilityNotification.Announcement(String(l10n: "Saved")).post() }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How long the check stands, muted, once it has drawn itself, before the part is at rest with no mark.
    private static let checkStands: Duration = .seconds(1.5)

    /// **The part "Value" of a key's card** (the owner's "Yes, both" of 21 November 2026 to its drawing, and "Yes, ring
    /// and check"): one secure field "New value" at the card's width, Return presses Replace; Cancel and Replace at the
    /// end of one row, and at its start the key save's mark while Replace runs and as its check draws, with no words
    /// (`KeySaveMark`); under them the muted line. Cancel empties the field, and Esc stays the card's. No moving words
    /// stand here (the rule of 28 October 2026: none straight in a modal card's stack): the ring says the wait.
    private var valueForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField(text: loginField.password, prompt: Text(verbatim: "")) { Text("New value") }
                .fieldPlaceholder(String(l10n: "New value"), shows: login.password.isEmpty)
                .fleetField()
                .frame(maxWidth: .infinity)
                .disabled(busy)
                .onSubmit { if canSave { Task { await save() } } }
                .onChange(of: login.password) { _, now in if !now.isEmpty { mark { $0.rest() } } }
                .accessibilityIdentifier("secret-value")
            HStack(spacing: 8) {
                if let look = valueMark {
                    KeySaveMark(saved: look == .saved, draws: true).transition(.opacity)
                }
                Spacer(minLength: 8)
                Button("Cancel") { clear(); message = nil }.buttonStyle(FleetOutlineButtonStyle())
                    .disabled(busy || login.password.isEmpty).accessibilityIdentifier("secret-value-cancel")
                Button(saveLabel) { Task { await save() } }.buttonStyle(FleetPrimaryButtonStyle())
                    .disabled(!canSave).accessibilityIdentifier("secret-save")
            }
            Text("The same agents keep it. Nobody sees the old or the new value.")
                .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
        // the check draws itself, goes quiet, stands a moment, and the part is at rest
        .task(id: valueMark) {
            guard valueMark == .saved else { return }
            do { try await Task.sleep(for: KeySaveMark.settles + Self.checkStands) } catch { return }
            mark { $0.rest() }
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
                stepField(String(l10n: "User name or email"), text: loginField.username, secure: false, id: "secret-user")
                stepField(String(l10n: "Password"), text: loginField.password, secure: true, id: "secret-password")
            } else {
                stepField(String(l10n: "Key"), text: loginField.password, secure: true, id: "secret-password")
            }
            // The secret's note, only where the request gave one: he reads it here and can change it.
            if noteField {
                stepField(String(l10n: "Note"), text: noteWordsField, secure: false, id: "secret-note")
                    .help(secretNote).onChange(of: secretNote) { old, now in noteChanged(old, now) }
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
            Held { LoadingLine(busy ? (sendingWords ? String(l10n: "Sending…") : String(l10n: "Saving…")) : String(l10n: "Reading Founderizer Vault…"), waits: false).padding(.vertical, 12) }
        }
    }

    private var form: some View {
        Group { if fieldsAlone { stepFields } else { rows } }
            .disabled(busy)
            .onChange(of: login.kind) { _, kind in
                // The other kind's fields go: a password never becomes a key, and the reverse.
                var fresh = LoginSecret(); fresh.kind = kind
                login = fresh; withSeed = false; sameName = nil; message = nil
                dropLevels()
            }
            .onChange(of: login.title) { _, _ in sameName = nil; dropLevels() }
            .onChange(of: login) { _, _ in centralLogin = nil }
    }

    private var rows: some View {
        // The page header or the request's card says what this is: the form's card has no heading of its own, and a
        // request's form has no footer either (the owner, 29 October 2026: "the panel should be much more compact").
        FormSection(footer: isRequest ? nil : footer) {
            if !isRequest {
                FormRow("Kind") {
                    FleetSegmented("Kind", selection: loginField.kind,
                                   options: [FleetOption(LoginSecret.Kind.login, "Login"), FleetOption(LoginSecret.Kind.apiKey, "API key")])
                        .accessibilityIdentifier("secret-kind")
                }
            }
            if login.kind == .login {
                if !knowsSite {
                    FormRow("Address", detail: String(l10n: "The sign-in page, with https://.")) {
                        TextField(text: loginField.url, prompt: Text(verbatim: "")) { Text("https://") }
                            .fieldPlaceholder("https://", shows: login.url.isEmpty).fleetField().frame(width: 260).accessibilityIdentifier("secret-url")
                    }
                }
                FormRow("User name") { TextField(text: loginField.username, prompt: Text(verbatim: "")) { Text("User name or email") }
                    .fieldPlaceholder(String(l10n: "User name or email"), shows: login.username.isEmpty).fleetField().frame(width: 260).accessibilityIdentifier("secret-user") }
                FormRow("Password") { SecureField(text: loginField.password, prompt: Text(verbatim: "")) { Text("Password") }
                    .fieldPlaceholder(String(l10n: "Password"), shows: login.password.isEmpty).fleetField().frame(width: 260).accessibilityIdentifier("secret-password") }
                // A request asks for the login alone: an authenticator's seed, if a site needs one, goes in on Secrets.
                if !isRequest {
                    if withSeed {
                        FormRow("2FA code", detail: String(l10n: "The authenticator's seed, or its otpauth:// address. The vault types the code at sign-in.")) {
                            SecureField(text: loginField.totp, prompt: Text(verbatim: "")) { Text("Seed") }
                                .fieldPlaceholder(String(l10n: "Seed"), shows: login.totp.isEmpty).fleetField().frame(width: 260).accessibilityIdentifier("secret-totp")
                        }
                    } else {
                        FormRow("2FA code", detail: String(l10n: "Optional.")) {
                            Button("Add 2FA code") { withSeed = true }.buttonStyle(FleetOutlineButtonStyle()).accessibilityIdentifier("secret-add-totp")
                        }
                    }
                }
            } else {
                // A request for a new value of a key has the Key row and the note alone: its key is the card's title.
                if isRequest && !preset.env.isEmpty {
                    if preset.replace == nil {
                        FormRow("Variable name") {
                            Text(preset.env).font(FormMetrics.text.monospaced()).textSelection(.enabled)
                                .accessibilityIdentifier("secret-env")
                        }
                    }
                } else {
                    FormRow("Variable name", detail: String(l10n: "The agent's name for the key, for example OPENAI_API_KEY.")) {
                        TextField(text: loginField.env, prompt: Text(verbatim: "")) { Text("OPENAI_API_KEY") }
                            .fieldPlaceholder("OPENAI_API_KEY", shows: login.env.isEmpty).font(FormMetrics.text.monospaced()).fleetField().frame(width: 260)
                            .accessibilityIdentifier("secret-env")
                    }
                }
                FormRow("Key") { SecureField(text: loginField.password, prompt: Text(verbatim: "")) { Text("Key") }
                    .fieldPlaceholder(String(l10n: "Key"), shows: login.password.isEmpty).fleetField().frame(width: 260).accessibilityIdentifier("secret-password") }
                if !knowsSite && preset.replace == nil {
                    FormRow("Service address", detail: String(l10n: "Optional. With it, an agent can call the service with the key (call_api).")) {
                        TextField(text: loginField.url, prompt: Text(verbatim: "")) { Text("https://api.example.com") }
                            .fieldPlaceholder("https://api.example.com", shows: login.url.isEmpty).fleetField().frame(width: 260).accessibilityIdentifier("secret-url")
                    }
                }
            }
            if noteField {
                FormRow("Note") { TextField(text: noteWordsField, prompt: Text(verbatim: "")) { Text("Note") }
                    .fieldPlaceholder(String(l10n: "Note"), shows: secretNote.isEmpty).fleetField().frame(width: 260).accessibilityIdentifier("secret-note")
                    .help(secretNote).onChange(of: secretNote) { old, now in noteChanged(old, now) } }
            }
            waitRow
        }
    }

    private var footer: String {
        login.problem == nil
            ? String(l10n: "Founderizer shows it as “\(login.title)”. Founderizer Vault keeps it, and gives it to the servers of the agents that get it. No agent sees it.")
            : String(l10n: "Founderizer Vault keeps it, and gives it to the servers of the agents that get it. No agent sees it.")
    }

    // MARK: who gets it

    /// What an agent's row offers: no access, use through its vault, and for an API key, read in its sessions.
    private enum Level: Hashable { case off, use, read }

    /// **Who can use it** (the owner, 21 November 2026, of a key request's card with a row for each of eleven agents:
    /// "do not show all agents, show the agent icons as the attached and the names on hover each one of them, for every
    /// group of agents with the same access level, and a link to Manage that expands the agents rows like you already do
    /// by default", "Subtitle at the bottom does not need to show at all", "No, no access does not need to show at
    /// all", and of Add secret, "well if it's the same idea, then it should also apply"): a line for each level that
    /// has agents, Uses it and then Reads it, with their faces (`SecretsList.accessLines`), and the link Manage, which
    /// opens the row of each agent with its control, as before, for as long as the form stands. A new key has no agent
    /// with access, so it shows the link alone. The section has no footer. What the rows give is the same either way.
    private var accessChoice: some View {
        let lines = SecretsList.accessLines(access, holders: holders, login: login.kind == .login)
        return VStack(alignment: onStep ? .center : .leading, spacing: 10) {
            FormSection(compact ? nil : String(l10n: "Who can use it")) {
                if managing {
                    ForEach(holders, id: \.self) { agent in accessRow(agent) }
                } else {
                    ForEach(lines, id: \.level) { line in accessLine(line) }
                }
            }
            if !managing {
                Button { managing = true } label: {
                    Text("Manage").padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // the hand under the pointer, as a link shows it, over all that a click reaches (Details' own way)
                .pointerStyle(.link)
                .padding(.vertical, -IconMetrics.reach)
                // the size of the card's Details link (12 points), and of a step's own link on a step
                .font(onStep ? SetupMetrics.textFont : FormMetrics.detail).foregroundStyle(FleetStyle.link)
                .help("Show each agent with its access")
                .accessibilityIdentifier("secret-manage")
            }
        }
    }

    /// **One level of Who can use it, closed**: the level's mark and word as its control shows them, then the faces of
    /// its agents, which overlap, each with its name under the pointer, and "+N" past `SecretsList.lineFaces`, with the
    /// names that it stands for under the pointer, so a line never grows past the 340 points of a card's own window.
    /// The level's word begins where an open row's name begins (50 points in, `RowMark`). VoiceOver reads the level and
    /// the names.
    private func accessLine(_ line: SecretsList.AccessLine) -> some View {
        let reads = line.level == .read
        let word = reads ? String(l10n: "Reads it") : String(l10n: "Uses it")
        let (shown, rest) = SecretsList.lineFaces(line.agents)
        return HStack(spacing: 10) {
            HStack(spacing: 0) {
                RowMark { Image(systemName: reads ? "eye" : "lock").font(IconMetrics.symbol(12)).foregroundStyle(FleetStyle.muted) }
                Text(word).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(1).fixedSize()
            }
            HolderFaces(names: shown, named: true)
            if !rest.isEmpty {
                Text(verbatim: String(l10n: "+\(rest.count)")).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).monospacedDigit()
                    .lineLimit(1).fixedSize()
                    .help(rest.map(\.agentLabel).joined(separator: ", "))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 8).frame(minHeight: 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(l10n: "\(word): \(line.agents.map(\.agentLabel).joined(separator: ", "))"))
        .accessibilityIdentifier("secret-level-\(line.level.rawValue)")
    }

    private func accessRow(_ agent: String) -> some View {
        let name = agent.agentLabel
        let level: Level = access[agent].map { login.kind == .login || $0 == .use ? Level.use : Level.read } ?? Level.off
        var rows = [FleetOption(Level.off, "No access", mark: .symbol("slash.circle")),
                    FleetOption(Level.use, "Uses it", subtitle: String(l10n: "\(name) uses it and never sees it."), mark: .symbol("lock"))]
        if login.kind == .apiKey {
            rows.append(FleetOption(Level.read, "Reads it", subtitle: String(l10n: "The key is in its sessions. \(name) can copy it."), mark: .symbol("eye")))
        }
        let title = level == .read ? String(l10n: "Reads it") : level == .use ? String(l10n: "Uses it") : String(l10n: "No access")
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
                touched.insert(agent); proposed.remove(agent); raised[agent] = nil
            } label: {
                FleetSelectLabel(title: title, mark: .symbol(mark))
            }.accessibilityIdentifier("secret-give-\(agent)")
        }
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 8).frame(minHeight: 44)
    }

    /// A replace: each agent's level of now goes into the rows that the owner did not set, so the form says who has
    /// the key, and not "No access" for an agent that has it.
    private func showLevels(of reference: String, _ entry: TeamLogin) {
        dropLevels()        // first his own rows again: the levels of a key that the rows showed before are no pick of his
        let shown = SecretReplaceAccess.rows(now: entry.grants, holders: holders, set: access, touched: touched, proposed: proposed)
        access = shown.rows; touched = shown.touched; raised = shown.raised
        levelsOf = reference; levelsEntry = entry
    }

    /// The name is no longer the key's whose levels the rows show: those levels leave the rows. A row that he set is
    /// his own pick again, a request's row is its proposal again, and each other row is empty.
    private func dropLevels() {
        guard levelsOf != nil else { return }
        access = SecretReplaceAccess.own(rows: access, holders: holders, touched: touched, raised: raised, proposal: preset.give,
                                         proposed: proposed)
        raised = [:]; levelsOf = nil; levelsEntry = nil
    }

    // MARK: a request

    /// The secrets of the catalog that already fit the request: one that was saved before can answer it, so the
    /// owner does not type it twice.
    private var fits: some View {
        FormSection(compact ? nil : String(l10n: "In the vault already"),
                    footer: String(l10n: "Answer with it, or save a new one below.")) {
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
        FormSection(compact ? nil : String(l10n: "Saved")) {
            if progress.sealed != nil {
                FormRow(progress.replaces ? SameName.notInVault(progress.title) : String(l10n: "“\(progress.title)” is not in the vault yet"),
                        symbol: "exclamationmark.circle", detail: progress.login, warning: progress.sealedProblem)
            } else {
                FormRow("“\(progress.title)” is in the vault", symbol: "checkmark.circle", detail: progress.login)
            }
            ForEach(progress.grants, id: \.agent) { grant in
                FormRow(grant.done ? Self.holds(grant) : Self.waits(grant),
                        symbol: grant.done && !grant.warning ? "checkmark.circle" : "exclamationmark.circle",
                        detail: grant.warning ? nil : grant.note, warning: grant.warning ? grant.note : nil)
            }
            if !progress.needs.isEmpty {
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
        switch grant.grant {
        case .read: String(l10n: "\(grant.agent.agentLabel) reads it in its sessions")
        case .use: String(l10n: "\(grant.agent.agentLabel) can use it")
        case nil: SameName.tookBack(grant.agent.agentLabel)
        }
    }

    /// The row of a step that is not done: the agent does not have the secret yet, or still has the one to take back.
    private static func waits(_ grant: SecretProgress.Grant) -> String {
        grant.grant == nil ? SameName.notTakenBack(grant.agent.agentLabel) : String(l10n: "\(grant.agent.agentLabel) does not have it yet")
    }

    // MARK: steps

    /// The form as the preset opens it: the request's kind, name and address, and never a value.
    private static func blank(_ preset: SecretPreset) -> LoginSecret {
        var login = LoginSecret()
        login.kind = preset.kind; login.env = preset.env; login.url = preset.url
        if preset.kind == .login { login.username = preset.account }
        return login
    }

    private func clear() { login = Self.blank(preset); sameName = nil; withSeed = false }

    /// The Note field holds no more than the hub takes (`NeedSecret.noteMost`, by `NeedSecret.noteLength`), so what he
    /// reads there is what goes; and the line about a key in the note leaves once the note holds none.
    private func noteChanged(_ old: String, _ now: String) {
        if NeedSecret.noteLength(now) > NeedSecret.noteMost {
            // A change that makes the note one character longer than it was, and too long, does not go in: a typed
            // character, anywhere in the note. Any other change that is too long is cut at the end of the note.
            secretNote = now.count == old.count + 1 && NeedSecret.noteLength(old) <= NeedSecret.noteMost
                ? old : NeedSecret.cut(now, most: NeedSecret.noteMost, note: true)
        } else if message == Self.keyInNote, !holdsKey(now) { message = nil }
    }

    private func text(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? String(l10n: "The hub did not answer.") }

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
        guard preset.replace == nil, let asked = need?.secret, let context, let team = try? await client.team(hub: context.hub, database: context.db) else { return }
        fitting = (team.logins ?? [:]).filter { $0.value.isAPIKey == (asked.kind == .apiKey) && asked.fits(title: $0.value.name) }
            .sorted { $0.key < $1.key }.map { Fit(login: $0.key, entry: $0.value) }
    }

    private func save() async {
        guard !busy else { return }
        message = nil
        if let problem = login.problem { message = problem; return }
        // C42: a value that the central vault never takes, said before anything is sent, so the list keeps no entry
        // with no value; Save stays as it is, so the owner reads why here
        if let problem = login.vaultProblem { message = problem; return }
        // The note is in the fleet's settings, not in the vault: one that looks like a key, or that holds the value of
        // this very form, stops the save before anything is sent.
        if showsNote, holdsKey(noteWords) { message = Self.keyInNote; noteOpened = true; return }
        guard let context else { message = String(l10n: "No current status of this hub. Nothing was sent."); return }
        guard let central else { phase = .noVault; return }
        busy = true
        defer { busy = false; saving = false }
        let title = login.title, kind = login.kind, variable = login.variable
        var grants = chosen
        // The key of the list whose value this save replaces: the one API key with this variable name.
        var replacing: (reference: String, entry: TeamLogin)?
        // Before anything is sent: the hub answers for this generation, and its catalog has room.
        do {
            let team = try await client.team(hub: context.hub, database: context.db)
            guard let catalog = team.logins else { message = String(l10n: "This hub has no list of secrets. Nothing was sent."); return }
            // **A new value of a key that the card names, in one press** (`SecretValueReplace`): the part "Value", and a
            // request for a new value of a key that the fleet holds. Its key, by its reference and its variable name; no
            // orange line first, and no access step: the same agents keep it.
            if let reference = preset.replace {
                let replaces = features.contains(CentralVault.replaceFeature) && GrantSigning.offered(store)
                switch SecretValueReplace.plan(reference, variable: preset.env, in: catalog, canReplace: replaces) {
                case .gone: message = String(l10n: "This secret is no longer in the list."); return
                case .notYet: message = SameName.notYet(title); return
                case .replace(let entry): replacing = (reference, entry); grants = []
                }
            } else {
                // The entry of a central save that the hub did not confirm is this very save, not a second secret.
                switch SecretNameHeld.of(title, kind: kind, in: catalog, but: centralLogin) {
                case .none:
                    // No key of this name (any more): rows that the form filled with a key's levels are not his choice
                    // for a new key, so they give nothing.
                    if levelsOf != nil { dropLevels(); grants = chosen }
                case .twice: dropLevels(); message = SameName.twice(title); return
                case .second:
                    if sameName != title { sameName = title; message = SameName.second(title); return }
                case .key(let reference, let entry):
                    guard features.contains(CentralVault.replaceFeature), GrantSigning.offered(store) else {
                        message = SameName.notYet(title); return
                    }
                    if sameName != title || levelsOf != reference {
                        // The first Save: the line says what the next one does, and the rows show who has the key now.
                        sameName = title; message = SameName.replaces(title)
                        showLevels(of: reference, entry)
                        return
                    }
                    replacing = (reference, entry)
                    // The same agents keep the key: only a row that he set himself makes a step, and no access takes
                    // the key back from an agent that has it.
                    grants = SecretReplaceAccess.changes(now: entry.grants, holders: holders, rows: access, set: touched, proposed: proposed,
                                                         raised: raised)
                        .map { SecretProgress.Grant(agent: $0.agent, grant: $0.grant) } + doorGrant
                }
            }
            guard replacing != nil || catalog.count < LoginSecret.maxCatalog else {
                message = String(l10n: "The list has \(LoginSecret.maxCatalog) secrets and takes no more. Nothing was sent."); return
            }
        } catch { message = String(l10n: "The hub did not answer for this save. Nothing was sent. \(text(error))"); return }
        // **The ring from here** (`KeySaveLook`): a line of its own above (a key of the same name, a full list, no
        // answer) ends the save with the form open, and a ring for that one round trip only made the card jump.
        saving = true
        await saveCentral(to: central, context: context, title: title, kind: kind, variable: variable, grants: grants,
                          replacing: replacing)
    }


    /// A save into the central vault. The value is sealed to the vault's key first, so it leaves the form as soon as
    /// the hub has the reference: then the sealed value, which only that vault opens, is all that is left of it here.
    /// A hub that does not confirm the reference leaves the fields as typed, and Save again goes under the same one.
    ///
    /// `replacing`: the key of the list whose value this save replaces. The save goes under that key's own reference,
    /// with the owner's signed statement about the sealed copy, which is made before anything is sent: a Mac that
    /// cannot sign sends nothing. The hub's step registers the fingerprints of the new value and gets the entry's own
    /// title and variable name back, so the entry, its site and its grants are not touched.
    private func saveCentral(to recipient: String, context: (hub: URL, db: String), title: String, kind: LoginSecret.Kind,
                             variable: String?, grants: [SecretProgress.Grant],
                             replacing: (reference: String, entry: TeamLogin)? = nil) async {
        // A new value in one press seals the key alone: an address in it would take the place of the key's own.
        guard let value = try? (preset.replace != nil ? SecretValueReplace.value(login) : login.value()) else {
            message = String(l10n: "This secret cannot be sent. Nothing was sent."); return
        }
        let sealed: String
        do { sealed = try AgeSeal.seal(value, to: recipient) }
        catch { message = String(l10n: "Founderizer could not seal it for the vault. Nothing was sent."); return }
        let reference = replacing?.reference ?? centralLogin ?? "bws://\(UUID().uuidString.lowercased())"
        var signed: (statement: String, signature: String)?
        if replacing != nil {
            do { signed = try await GrantSigning.replace(login: reference, sealed: sealed, store: store, hub: context.hub, database: context.db) }
            catch { message = String(l10n: "\(text(error)) Nothing was sent."); return }
        } else {
            centralLogin = reference
        }
        do {
            // A replace keeps the entry's site, and the hub gives no site from an address then: it sends none.
            try await Self.register(reference, title: replacing?.entry.title ?? title, kind: kind,
                                    variable: replacing != nil ? replacing?.entry.env : variable,
                                    address: replacing == nil ? SecretCommand.address(for: login, features: store.state?.ui_features) : nil,
                                    value: value, hub: context.hub, database: context.db, installation: store.installation)
        } catch {
            // The hub takes no new secret while the central vault does not answer: nothing was sent.
            if case HubError.refusal(let refused) = error, refused.status == 503 { central = nil; phase = .noVault; return }
            // In the one-press mode the line with "Save again" does not fit: its button says Replace.
            message = preset.replace != nil ? String(l10n: "Founderizer could not change this. \(text(error))")
                : String(l10n: "The hub did not register this secret. \(text(error)) Save again to try once more.")
            return
        }
        clear(); centralLogin = nil
        // A new value of a key of the list also answers each open request for a new value of that key: it would stay
        // open for a value that the vault has already.
        let needs = SecretValueReplace.answers(own: preset.need, replacing: replacing?.reference, in: store.state?.needs ?? [])
        let progress = SecretProgress(login: reference, title: title, kind: kind, grants: grants, need: preset.need, needs: needs,
                                      note: showsNote ? noteWords : nil, tell: preset.tell,
                                      sealed: sealed, statement: signed?.statement, signature: signed?.signature)
        phase = .saved(progress)
        await proceed(progress)
    }

    /// A secret of the catalog answers the request: the agents that the owner chose get it, then the request its answer.
    private func answerWith(_ reference: String, entry: TeamLogin) async {
        guard !busy else { return }
        busy = true         // the rows do not change while the levels are read again
        defer { busy = false; saving = false }
        let kind: LoginSecret.Kind = entry.isAPIKey ? .apiKey : .login
        // While the rows show the levels of now of this very key (after a Save that found the name), the answer is
        // what the rows say against those levels, as for the Save that replaces: a row that he set to no access takes
        // the key back, and a row that he did not set changes nothing.
        let grants: [SecretProgress.Grant]
        if levelsOf == reference {
            // The levels of now, read again: `entry` is from when the request's form opened, and the rows show the
            // levels of a later Save. When the hub does not answer, the entry of that Save.
            var now = levelsEntry ?? entry
            if let context, let fresh = (try? await client.team(hub: context.hub, database: context.db))?.logins?[reference] { now = fresh }
            grants = SecretReplaceAccess.changes(now: now.grants, holders: holders, rows: access, set: touched, proposed: proposed,
                                                 raised: raised)
                .map { SecretProgress.Grant(agent: $0.agent, grant: $0.grant) } + doorGrant
        } else {
            // The rows show no levels, or the levels of another key: then the answer gives what he set himself and
            // what the request proposes, and nothing of a level that the form put into a row for that other key.
            let rows = levelsOf == nil ? access : SecretReplaceAccess.own(rows: access, holders: holders, touched: touched, raised: raised,
                                                                          proposal: preset.give, proposed: proposed)
            grants = holders.compactMap { agent in rows[agent].map { SecretProgress.Grant(agent: agent, grant: kind == .login ? .use : $0) } }
                + doorGrant
        }
        // The note as the card shows it, only to a secret of the list with no note of its own and of the account that
        // the request names, or of any account when it names none (`NeedSecret.noteGoes`); else none, and the secret
        // keeps what it has. A note that looks like a key stops the answer here, before anything is sent, with the
        // line of a save: read before the fields are cleared, so that the value of the form's own field counts too.
        let goes = showsNote && need?.secret?.noteGoes(to: entry) == true
        if goes, holdsKey(noteWords) { message = Self.keyInNote; noteOpened = true; return }
        let noted = goes ? noteWords : nil
        saving = true       // the ring, past the line of a note that looks like a key
        clear()
        let progress = SecretProgress(login: reference, title: entry.name, kind: kind, grants: grants, need: preset.need, note: noted,
                                      tell: nil)
        phase = .saved(progress)
        await proceed(progress)
    }

    /// The steps after the registration, each once: the sealed value to the central vault, the grants, each signed with
    /// the owner key first (`GrantSigning`), the answer of the request and the message to the chat's agent. A step that
    /// is done is not done again; Try again runs the rest. Nothing follows a save before the vault has its value: an
    /// agent told of a secret that is in no vault would ask for it in vain.
    private func proceed(_ start: SecretProgress) async {
        guard let context else { message = String(l10n: "No current status of this hub. Try again when it answers."); return }
        var progress = start
        let wasBusy = busy
        busy = true
        defer { busy = wasBusy }
        message = nil
        let secrets = SecretsClient(), installation = store.installation
        if let sealed = progress.sealed {
            do {
                _ = try await VaultClient().intake(hub: context.hub, database: context.db, client: installation, login: progress.login,
                                                   ciphertext: sealed, statement: progress.statement, signature: progress.signature)
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
                // A grant is signed for the central vault before the hub has it, and its end after (`GrantSigning`),
                // as on the key's own page: the vault's signed grants always include the hub's.
                if wanted.grant != nil {
                    try await GrantSigning.grant(wanted.grant, login: progress.login, agent: wanted.agent, store: store,
                                                 hub: context.hub, database: context.db)
                }
                let receipt = try await secrets.grant(hub: context.hub, database: context.db, client: installation, login: progress.login,
                                                      agent: wanted.agent, grant: wanted.grant)
                if wanted.grant == nil {
                    try await GrantSigning.grant(nil, login: progress.login, agent: wanted.agent, store: store, hub: context.hub,
                                                 database: context.db)
                }
                let note = Self.note(receipt, title: progress.title)
                progress.grants[index].done = true
                progress.grants[index].note = note?.text; progress.grants[index].warning = note?.warning ?? false
            } catch {
                progress.grants[index].note = "\(wanted.grant == nil ? SameName.takeBackFailed : String(l10n: "Not given.")) \(text(error))"
                progress.grants[index].warning = true
            }
            phase = .saved(progress)
        }
        if !progress.answered {
            progress.answerProblem = nil
            for need in progress.needs where !progress.answeredNeeds.contains(need) {
                let own = need == progress.need
                do {
                    // the secret's note goes with the form's own request alone
                    _ = try await secrets.answer(hub: context.hub, database: context.db, client: installation, need: need,
                                                 requestID: progress.answerIDs[need] ?? UUID(), login: progress.login,
                                                 note: own ? progress.note : nil)
                    progress.answeredNeeds.insert(need)
                    if own { forgetDraft() }        // the request has its answer: words that he left in its message field go
                } catch {
                    // A request that had its answer already, here or on another of this Mac's views of it, takes no other.
                    if case HubError.refusal(let refused) = error, refused.status == 409, refused.means(.requestAnswered) {
                        progress.answeredNeeds.insert(need)
                        if own { progress.answerNote = String(l10n: "It had an answer already.") }
                    } else if progress.answerProblem == nil { progress.answerProblem = text(error) }
                }
            }
            phase = .saved(progress)
        }
        if let agent = progress.tell, !progress.told {
            if await store.say(Self.telling(progress), to: agent) { progress.told = true; progress.tellProblem = nil }
            else { progress.tellProblem = store.sendError ?? String(l10n: "Founderizer could not send the message now. Try again.") }
            phase = .saved(progress)
        }
        await store.refresh()
        // From the chat, the message under the conversation says it all: the form goes once every step is done.
        if progress.isDone && progress.tell != nil && !progress.given.contains(where: \.warning) {
            onDone(progress.login)
        }
        // A key page goes on once the vault has the key: the add's next writes are its page's (the account, the agent
        // and its grant), and the form shows its field again for a line of theirs.
        if preset.keyStep && progress.isDone {
            phase = .form
            onDone(progress.login)
        }
        // **The part "Value" is at rest again once every step is done**: its field, empty, and the check at the start of
        // its row, which draws itself there (`KeyValueMark`) and then goes. The check came already when the steps were
        // done before the read of the hub: a read that took longer than the check stands draws it no second time.
        if preset.valuePart && progress.isDone {
            mark { $0.take(.saved) }
            saving = false
            phase = .form
            onDone(progress.login)
        }
    }

    /// The owner's message in the chat that Add secret was opened from: the secret's name and reference, who holds it
    /// and where it is. It names no value, because the app has none to name.
    static func telling(_ progress: SecretProgress) -> String {
        var words = [progress.replaces ? SameName.told(progress.title)
                     : "I saved \(progress.kind == .apiKey ? "the API key" : "the login") \(progress.title) in the vault, as \(progress.login)."]
        // an agent that the owner took the key back from is no holder: the message names who got it
        let given = progress.given.filter { $0.grant != nil }
            .map { "\($0.agent) \($0.grant == .read ? "reads it as $\(progress.title)" : "uses it through its vault")" }
        // After a replace, the agents that held the key keep it: only a new secret can have no holder yet.
        if given.isEmpty { if !progress.replaces { words.append("No agent holds it yet.") } }
        else { words.append((given.count == 1 ? given[0] : given.dropLast().joined(separator: ", ") + " and " + given[given.count - 1]) + ".") }
        return words.joined(separator: " ")
    }

    /// What the owner must know after a grant: the agent's vault access, or when it reads the key.
    private static func note(_ receipt: SecretGrantReceipt, title: String) -> (text: String, warning: Bool)? {
        let name = receipt.agent.agentLabel
        if let vault = receipt.vault {
            if vault.after == "broker" { return (String(l10n: "\(name) uses its server's vault now."), false) }
            let reasons = (vault.missing ?? []).map(VaultAccessControl.reason).joined(separator: " ")
            return (String(l10n: "\(name) has it, but it has no vault access yet, so it cannot use it now. \(reasons)"), true)
        }
        if receipt.grant == SecretGrant.read.rawValue && receipt.changed {
            return (String(l10n: "\(name) reads $\(title) in its sessions from their next start."), false)
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
            forgetDraft()
            await store.refresh()
            onDone(nil)
        } catch {
            if case HubError.refusal(let refused) = error, refused.status == 409 { declineID = UUID() }      // the request had its answer; a new one is another command
            message = String(l10n: "The decline did not reach the hub. \(text(error))")
        }
    }

    /// **Needs clarification**: his words about the request go to the hub, which closes the request with them and
    /// gives them to the agent that asked. Words that look like a key stay here (`keyInWords`); the hub refuses a
    /// registered login in them too.
    private func clarify() async {
        guard let need = preset.need, let context, canClarify else { return }
        let words = clarifyWords
        if holdsKey(words) { message = Self.keyInWords; return }
        busy = true; sendingWords = true
        defer { busy = false; sendingWords = false }
        message = nil
        do {
            _ = try await SecretsClient().clarify(hub: context.hub, database: context.db, client: store.installation, need: need,
                                                  requestID: clarifyID, words: words)
            clear()
            forgetDraft()
            clarifyText = ""
            await store.refresh()
            onDone(nil)
        } catch {
            if case HubError.refusal(let refused) = error, refused.status == 409 { clarifyID = UUID() }      // the request had its answer; a new one is another command
            message = String(l10n: "Your message did not reach the hub. \(text(error))")
        }
    }
}

extension EnvironmentValues {
    /// **A key request's card says whether its Details are open** (`NeedRequestCard`, `NeedStep`), and the field of the
    /// request's note shows only then (`SecretEntryView.noteField`); true everywhere else.
    @Entry var requestNoteShows = true
}

extension SecretEntryView {
    /// **The hub's half of a save into the central vault**, which Add secret's form and the import of secrets from
    /// another password manager (`SecretImportView`) both make, so that there is one rule for it: the fingerprints of
    /// the value, made here from the salts that the hub gives for this reference, and the catalog entry under it. The
    /// hub takes the same reference again, so a save that it did not confirm goes under the same one. The value does
    /// not leave this call. `address`: an API key's address for the hub's table of well-known services, as
    /// `SecretCommand.address(for:features:)` gives it, or nil.
    static func register(_ reference: String, title: String, kind: LoginSecret.Kind, variable: String?, address: String? = nil,
                         value: Data, hub: URL, database: String, installation: String) async throws {
        let salts = try await HubClient().secretSalts(hub: hub, database: database, login: reference)
        _ = try await SecretsClient().add(hub: hub, database: database, client: installation, login: reference, title: title,
                                          kind: kind, variable: variable, address: address,
                                          fingerprints: SecretFingerprint.of(value, salts: salts))
    }
}
