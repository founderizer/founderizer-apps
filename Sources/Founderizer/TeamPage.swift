import FleetCore
import SwiftUI

/// The agent pages' reading of the profiles, and the edits of their rules. Each rule saves itself: after 2 seconds
/// without typing, and on Done or Back. Saves go one at a time through the store; a newer text of a rule that still
/// waits replaces the older one. A save sends every section of the version that the edit knows, with only this rule
/// changed. When the hub refuses it with 409 because the profile changed elsewhere, the save reads the profile again and
/// sends only this rule's change again, with no question; when that same rule changed elsewhere, the editor shows the
/// new text instead. An edit stays in memory while other pages show, until the app quits. A refused login text clears
/// the edits, as it clears every draft. Another hub or hub generation starts again with no reading and no edit.
@MainActor @Observable
final class TeamModel {
    struct EditKey: Hashable {
        let agent: String
        let id: ProfileSectionID
    }

    private(set) var reading: ProfileReading = .loading
    private(set) var edits: [EditKey: ProfileSectionEdit] = [:]
    private(set) var states: [EditKey: SaveState] = [:]
    private var order: [EditKey] = []
    private var versions: [EditKey: Int] = [:]
    /// Rules to delete. A failed delete stays here, so that Retry deletes again.
    private var deleting: Set<EditKey> = []
    private var draining = false
    /// The save that waits for the hub's answer: its Retry sends the same request again.
    private var unanswered: (key: EditKey, id: UUID)?
    private var context = ""
    private var reads = 0
    /// The newest read that answered: an older one that answers after it changes nothing.
    private var answered = 0

    func profile(_ agent: String) -> AgentProfile? { reading.list?.profiles.first { $0.agent == agent } }

    /// Reads every profile of the hub. The reading takes the answer of the newest read that answered: an older read
    /// that answers after a newer one changes nothing. Returns the list that this read got, also when a later read
    /// replaces it, or nil when the read failed. A first reading of a page that opened at `start` waits until a loading
    /// line that showed has stood half a second (`FleetStore.settle`).
    ///
    /// **A read that was cut off is no failure** (D-1 rule 2): a page that closes, or a read that the next one takes over,
    /// leaves the reading as it was. It made the profile "Last reading" in orange 52 ms into the read that would have
    /// confirmed it, and the Memory group under it moved 38 pt when the line went.
    @discardableResult func read(_ store: FleetStore, since start: ContinuousClock.Instant? = nil) async -> ProfileList? {
        guard let database = store.state?.db, store.state?.ui_features?.contains("profiles") == true else { return nil }
        let hub = store.hub, context = "\(hub.absoluteString)\n\(database)"
        if self.context != context { self.context = context; reading = .loading; clear(); answered = 0 }
        reads += 1
        let read = reads
        let first = reading.list == nil
        do {
            let list = try await HubClient().profiles(hub: hub, database: database)
            if first, let start { await store.settle(since: start) }
            guard self.context == context else { return nil }
            if read > answered { answered = read; reading = .current(list) }
            return list
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return nil }
            if first, let start { await store.settle(since: start) }
            // The hub writes one line for the owner beside the status it refused with; a `try?` here would drop it,
            // and the rows below would say "Last reading" and nothing about why.
            if self.context == context, read > answered {
                answered = read
                reading = reading.after(nil, reason: HubError.said(error))
            }
            return nil
        }
    }

    /// The edit of a rule for its editor: the one with the owner's unsaved text, else a new one from the profile.
    func begin(_ key: EditKey) {
        if let edit = edits[key], edit.isChanged || order.contains(key) || states[key]?.retries == true { return }
        guard let profile = profile(key.agent), let edit = ProfileSectionEdit(profile: profile, id: key.id) else { return }
        if edits[key] != edit { edits[key] = edit }
    }

    /// The edit of a new rule of this agent: the one that the owner started and did not add, else an empty one.
    func beginNew(agent: String) -> EditKey? {
        if let open = edits.first(where: { $0.key.agent == agent && $0.value.isNew }) { return open.key }
        guard let profile = profile(agent) else { return nil }
        let edit = ProfileSectionEdit(newRuleIn: profile)
        let key = EditKey(agent: agent, id: edit.id)
        edits[key] = edit; states[key] = nil
        return key
    }

    func setTitle(_ title: String, of key: EditKey) { edits[key]?.title = title }
    func setText(_ text: String, of key: EditKey) { edits[key]?.text = text }

    /// Saves a rule: at once when nothing else is sent, else after the requests before it.
    func save(_ key: EditKey, store: FleetStore) { enqueue(key, deleting: false, store: store) }
    /// Deletes a rule that the owner added, in the same queue.
    func delete(_ key: EditKey, store: FleetStore) { enqueue(key, deleting: true, store: store) }

    /// The same request again while it waits for its answer; else the save or delete again.
    func retry(_ key: EditKey, store: FleetStore) {
        if let unanswered, unanswered.key == key { Task { await store.retry() } }
        else { enqueue(key, deleting: deleting.contains(key), store: store) }
    }

    /// Drops a new rule that the owner did not add.
    func discard(_ key: EditKey) {
        guard edits[key]?.isNew == true, !order.contains(key) else { return }
        edits[key] = nil; states[key] = nil
    }

    /// Removes every edit: after a refused login text, and on another hub or hub generation.
    func clear() {
        edits = [:]; states = [:]; order = []; deleting = []; versions = [:]; unanswered = nil
    }

    private func enqueue(_ key: EditKey, deleting removing: Bool, store: FleetStore) {
        guard edits[key] != nil else { return }
        versions[key, default: 0] += 1
        if removing { deleting.insert(key) } else { deleting.remove(key) }
        set(.saving, for: key)
        if !order.contains(key) { order.append(key) }
        if !draining { Task { await drain(store: store) } }
    }

    /// A rule's save state, **with the motion of its line** (`SaveState.motion`): a failure's line and Try again come
    /// and go over 0.2 s, and the rules under them move with them.
    private func set(_ state: SaveState?, for key: EditKey) {
        withAnimation(SaveState.motion(from: states[key], to: state)) { states[key] = state }
    }

    private func drain(store: FleetStore) async {
        guard !draining else { return }
        draining = true; defer { draining = false }
        // The outcome of a save that a newer request of the same rule followed: it stays when there is nothing more to send.
        var earlier: [EditKey: SaveState] = [:]
        while let key = order.first {
            guard let edit = edits[key] else { order.removeFirst(); deleting.remove(key); set(nil, for: key); continue }
            let version = versions[key], removing = deleting.contains(key)
            let state: SaveState?
            if !removing && !edit.isChanged { state = earlier[key] }
            else if let problem = edit.problem(deleting: removing) { state = .failed(problem) }
            else { state = await send(edit, key: key, deleting: removing, store: store) }
            // A newer text of this rule waits: it goes next.
            guard versions[key] == version else { earlier[key] = state; continue }
            order.removeFirst()
            if state?.retries != true { deleting.remove(key) }
            set(state, for: key)
            if state == .saved {
                Task { try? await Task.sleep(for: .seconds(3)); if states[key] == .saved, versions[key] == version { states[key] = nil } }
            }
        }
    }

    /// One save or delete of a rule, again on the newer version after each 409 that a change elsewhere caused.
    private func send(_ first: ProfileSectionEdit, key: EditKey, deleting removing: Bool, store: FleetStore) async -> SaveState {
        var edit = first
        var words = String(l10n: "Not saved.")
        for _ in 0..<3 {
            guard let payload = try? edit.payload(deleting: removing) else { return .failed(String(l10n: "The hub cannot take this profile. Check the rule.")) }
            var result = await store.save(edit.command, note: payload, queue: false)
            if case .unconfirmed(let id) = result {
                unanswered = (key, id)
                // Its row and the rule's editor say it, so the window's request line leaves it out on Behaviour
                // (`pendingInItsRow`).
                store.pendingInItsRow = (id, key.agent, .behaviour)
                set(.failed(String(l10n: "The hub has not answered. Try again sends the same request.")), for: key)
                result = await store.answer(to: id)
                unanswered = nil
                if store.pendingInItsRow?.id == id { store.pendingInItsRow = nil }
                set(.saving, for: key)
            }
            switch result {
            case .saved(let sha256):
                if removing { edits[key] = nil } else if let sha256 { edits[key]?.update(after: edit, sha256: sha256) }
                await read(store)
                return .saved
            case .conflict(let reason):
                words = reason
                // The same version: the 409 was for another reason.
                guard let list = await read(store), let profile = list.profiles.first(where: { $0.agent == key.agent }),
                      profile.sha256 != edit.baseSHA256 else { return .failed(words) }
                var current = edits[key] ?? edit
                switch current.rebase(on: profile) {
                case .gone:
                    edits[key] = nil
                    return removing ? .saved : .failed(String(l10n: "Another change removed this rule, so this text was not saved."))
                case .sectionChanged:
                    // Another save gave the rule this same text: it is saved.
                    if !removing && !current.isChanged { edits[key] = current; return .saved }
                    edits[key] = ProfileSectionEdit(profile: profile, id: current.id)
                    return .changedElsewhere
                case .unchanged:
                    edits[key] = current
                    edit = current
                }
            case .refused(let reason): return .failed(reason)
            case .unconfirmed: return .failed(String(l10n: "The hub has not answered."))
            case .behind: return .behind
            }
        }
        return .failed(words)
    }
}

/// **Behaviour, one part of an agent** (the owner's yes of 28 October 2026 to D-5): its rules, what runs for it on a
/// schedule, and its memory, on one page. Each rule shows the first line of the rule as written, its save mark and
/// Edit, which opens the editor of that rule; what to write in a rule is the editor's placeholder. Add rule adds a rule
/// of the owner's own. Knowledge, logins and knowledge files are not rules: Settings › Knowledge and Secrets hold them.
///
/// **No duty and no case shows here** (the owner, 3 November 2026: "they dont need to show at all"): the agents keep
/// them, and "Responsible for" is the rule in his own words.
struct BehaviourView: View {
    @Bindable var store: FleetStore
    let team: TeamModel
    let agent: String
    let open: (Destination) -> Void
    /// When this visit began: its read of the profile has a second before the profile counts as old (`Held`).
    @State private var opened = ContinuousClock.now

    private var features: [String] { store.state?.ui_features ?? [] }
    private var memoryOffered: Bool { features.contains(AgentNotes.feature) || features.contains(AgentMemory.feature) }

    var body: some View {
        FleetPage(AgentTab.behaviour.heading) {
            if features.contains("profiles") { profileBlocks }
            TriggersView(store: store, agent: agent)
            if memoryOffered { AgentMemorySection(store: store, agent: agent, titled: String(l10n: "Memory")) }
        }
        // The schedules are read here, so a section with no rule draws nothing at all (`TriggersView.poll`).
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(agent)/schedules") { await TriggersView.poll(store: store) }
        .task(id: "\(store.hub.absoluteString)/\(store.state?.db ?? "")") {
            guard features.contains("profiles") else { return }
            let start = ContinuousClock.now
            while !Task.isCancelled {
                await team.read(store, since: start)
                do { try await store.nap(15) } catch { return }
            }
        }
    }

    @ViewBuilder private var profileBlocks: some View {
        if let profile = team.profile(agent) {
            rules(profile)
            if case .stale = team.reading {
                // Not before this visit's read has had its second (D-1 rule 2).
                Held(since: opened) {
                    Text(team.reading.lastReadingLine).font(FormMetrics.detail).foregroundStyle(.orange)
                }
            }
        } else {
            switch team.reading {
            // Before the first reading: the heading and its Add rule, and under them the line where the rules come.
            // While the hub does not answer nothing is read, and the profile is not read.
            case .loading where store.connectionError == nil:
                rules(nil)
                LoadingLine(String(l10n: "Reading the rules…"))
            // Not while the window's notice says the outage (`FleetStore.hubNoticeShows`; fix round 3, item 33): the
            // heading stands alone, with no Add rule, because the editor has nothing to edit without the profile.
            case .loading, .failed:
                if store.hubNoticeShows { rules(nil, adds: false) }
                else { EmptyState(symbol: "exclamationmark.circle", title: String(l10n: "Profile not read"), detail: team.reading.notReadDetail) }
            case .current, .stale: EmptyState(symbol: "doc.questionmark", title: String(l10n: "No profile"), detail: String(l10n: "The hub has no profile for \(agent.agentLabel)."))
            }
        }
    }

    /// The rules of its profile under their heading, with Add rule. Before the profile is read, the heading and Add rule
    /// stand alone: "+ Add rule" came 192 ms after the page (the loading contract, C4.2). The editor reads the profile
    /// itself, and only the reading says that a profile has its 16 sections.
    private func rules(_ profile: AgentProfile?, adds: Bool = true) -> some View {
        let full = (profile?.sections.count ?? 0) >= 16
        // No line under the heading (D-2): the rules say how the agent works.
        return FormSection("Rules") {
            ForEach(profile?.entries.filter(\.isRule) ?? []) { entry in row(entry) }
        } accessory: {
            if adds {
                Button { open(.agentRule(agent, nil)) } label: { Label("Add rule", systemImage: "plus") }
                    .buttonStyle(FleetOutlineButtonStyle()).disabled(full)
                    .help(full ? "A profile has at most 16 sections." : "Add a rule of your own.")
                    .accessibilityIdentifier("behaviour-add-rule")
            }
        }
    }

    /// **The first line of the rule as written** (D-5), where the row said what to write in it on every agent alike
    /// ("How this agent behaves and sounds, in one or two sentences."): that line is the editor's placeholder now.
    ///
    /// **One line, cut with "…"** (D-5: "each rule's first line"; fix round 2): a long first line wrapped to two lines and
    /// made a row of 70 pt among rows of 56. The whole line is its hover.
    private func row(_ entry: ProfileSectionEntry) -> some View {
        let key = TeamModel.EditKey(agent: agent, id: entry.id)
        let first = ProfilePreview(entry.section.text, lines: 1, width: 140).lines.first
        let warning = team.states[key]?.failure
        return HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(FormMetrics.title).foregroundStyle(FleetStyle.text)
                if let first, !first.isEmpty {
                    Text(first).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                        .truncationMode(.tail).help(first)
                }
                if let warning {
                    Text(warning).font(FormMetrics.detail).foregroundStyle(.orange).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.vertical, 10)
            Spacer(minLength: 16)
            HStack(spacing: 10) {
                SaveMark(state: team.states[key]) { team.retry(key, store: store) }
                Button("Edit") { open(.agentRule(agent, entry.id)) }.buttonStyle(FleetOutlineButtonStyle())
                    .accessibilityIdentifier("rule-edit-\(entry.id.key)-\(entry.id.occurrence)")
            }.padding(.vertical, 8)
        }
        .font(FormMetrics.text)
        .padding(.horizontal, FormMetrics.rowInset)
        .frame(minHeight: first?.isEmpty == false || warning != nil ? FormMetrics.twoLineRow : FormMetrics.row)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

/// The editor of one rule of an agent's Behaviour, over the whole page: its name and the one line on what to write in
/// it, the title of a rule that the owner added, and its text. It saves itself after 2 seconds without typing, and on
/// Done, Back or another page. A new rule is in the profile only after Add rule. A rule that the owner added can be
/// deleted.
struct RuleEditor: View {
    @Bindable var store: FleetStore
    let team: TeamModel
    let agent: String
    /// The rule; nil for a new one.
    let id: ProfileSectionID?
    let open: (Destination) -> Void
    @State private var newKey: TeamModel.EditKey?

    /// The rule; for a new one, the one Add rule began, or **before it is begun the one it will begin**.
    private var key: TeamModel.EditKey? {
        if let id { return TeamModel.EditKey(agent: agent, id: id) }
        if let newKey { return newKey }
        if let open = team.edits.first(where: { $0.key.agent == agent && $0.value.isNew }) { return open.key }
        return team.profile(agent).map { TeamModel.EditKey(agent: agent, id: ProfileSectionEdit(newRuleIn: $0).id) }
    }
    /// The edit of the rule, and **before the edit is begun, the rule as the profile has it**, so the editor's first frame
    /// is the rule (T-11): "Rule not found" stood 7–11 ms in its first layout, until the task below began the edit.
    private var edit: ProfileSectionEdit? {
        guard let key else { return nil }
        if let edit = team.edits[key] { return edit }
        guard let profile = team.profile(agent) else { return nil }
        return id == nil ? ProfileSectionEdit(newRuleIn: profile) : ProfileSectionEdit(profile: profile, id: key.id)
    }
    /// The edit is the model's, and not only this view's first frame of it.
    private var begun: Bool { key.map { team.edits[$0] != nil } ?? false }
    private var isNew: Bool { id == nil }
    private var state: SaveState? { key.flatMap { team.states[$0] } }

    var body: some View {
        // **The rule's name, its back link and Done stand where every sub-page has them** (`FleetPage`, T-11): the name
        // at the header's place, "‹ Behaviour" in the band over it, and the save mark with Done or Add rule at its
        // right. The editor drew a bar of its own: its title stood 28–48 pt under every other page's, and Done 11 pt
        // over the header's buttons.
        FleetPage(title, back: FleetBack("Behaviour") { close() }, fills: true) {
            // **The text's card is a form's card, 680 pt** (D-8 item 8): it took the page's 1,100 beside the 680-pt
            // cards of every other part of the agent.
            VStack(alignment: .leading, spacing: 14) {
                if let key, let edit { editor(edit, key: key) }
                else {
                    switch team.reading {
                    case .loading where store.connectionError == nil: LoadingLine(String(l10n: "Reading the rule…"))
                    // Not while the window's notice says the outage (`FleetStore.hubNoticeShows`).
                    case .loading, .failed:
                        if !store.hubNoticeShows {
                            EmptyState(symbol: "exclamationmark.circle", title: String(l10n: "Profile not read"), detail: team.reading.notReadDetail)
                        }
                    case .current, .stale:
                        EmptyState(symbol: "doc.questionmark", title: String(l10n: "Rule not found"), detail: state?.failure ?? String(l10n: "This profile has no such rule now."))
                    }
                    Spacer(minLength: 0)
                }
            }
            // **The line under the text comes and goes with the motion of a save's line** (`SaveState.lineMotion`; the
            // review of 30 October 2026): the text's box gives it its room over 0.2 s, where its bottom edge moved 30 pt
            // in one frame. A save's own line had the motion already; a rule's problem, a change made elsewhere and an old
            // reading had none.
            .animation(SaveState.lineMotion, value: edit.flatMap { status($0)?.text })
            .frame(maxWidth: FormMetrics.formWidth, maxHeight: .infinity, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .leading)
        } actions: { actions }
        .task(id: "\(store.hub.absoluteString)/\(store.state?.db ?? "")") {
            let start = ContinuousClock.now
            while !Task.isCancelled {
                await team.read(store, since: start)
                do { try await store.nap(15) } catch { return }
            }
        }
        // The edit comes from the profile when it is read, and again from each newer reading while it has no change, and
        // after a refused login text removed it.
        .task(id: "\(team.profile(agent)?.sha256 ?? "")/\(begun)") {
            if let id { team.begin(.init(agent: agent, id: id)) } else if !begun { newKey = team.beginNew(agent: agent) }
        }
        // 2 seconds without typing saves the rule.
        .task(id: edit.map { "\($0.title)\n\($0.text)" }) {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if let key, let edit, !edit.isNew, edit.isChanged { team.save(key, store: store) }
        }
        .onChange(of: state) { _, state in
            // A new rule that the hub added: its place is in the list now.
            if isNew, state == .saved { open(.agentDetail(agent, .behaviour)) }
        }
        .onDisappear { if let key, let edit, !edit.isNew, edit.isChanged { team.save(key, store: store) } }
    }

    /// The header's title: the rule's own name once it is read, else the name of its kind; "New rule" for one he adds.
    private var title: String {
        if let edit { return edit.isNew ? String(l10n: "New rule") : edit.name }
        return id.map { ProfileGuide.name(key: $0.key, title: String(l10n: "Rule")) } ?? String(l10n: "New rule")
    }

    /// The save state, and Done; Add rule for a new rule. Back to Behaviour is the page's back link (Esc).
    @ViewBuilder private var actions: some View {
        if let key { SaveMark(state: state) { team.retry(key, store: store) } }
        if isNew {
            // Once the rule can be added: no grey button (the owner: "dont show the send button if it's not
            // clickable"). While it saves, the save mark says so.
            if edit.map({ $0.problem() == nil }) == true && state != .saving && store.isFresh {
                Button("Add rule") { if let key { team.save(key, store: store) } }.buttonStyle(FleetPrimaryButtonStyle())
                    .accessibilityIdentifier("rule-add")
            }
        } else {
            Button("Done") { close() }.buttonStyle(FleetPrimaryButtonStyle()).accessibilityIdentifier("rule-done")
        }
    }

    @ViewBuilder private func editor(_ edit: ProfileSectionEdit, key: TeamModel.EditKey) -> some View {
        if edit.id.key == "other" {
            TextField(text: Binding(get: { team.edits[key]?.title ?? edit.title },
                                    set: { team.begin(key); team.setTitle($0, of: key) }), prompt: Text(verbatim: "")) { Text("Title") }
                .fieldPlaceholder(String(l10n: "Title"), shows: (team.edits[key]?.title ?? edit.title).isEmpty)
                .fleetField()
                .accessibilityIdentifier("rule-title")
        }
        TextEditor(text: Binding(get: { team.edits[key]?.text ?? edit.text }, set: { team.begin(key); team.setText($0, of: key) }))
            .font(FormMetrics.text)
            // The words where they stood: the box's own 7 points of room come out of the row's inset.
            .padding(.horizontal, FormMetrics.rowInset - 5 - 7).padding(.vertical, 10 - 7)
            // **What to write in the rule is the field's placeholder** (D-5): the list shows the rule's own first line.
            .overlay(alignment: .topLeading) {
                if (team.edits[key]?.text ?? edit.text).isEmpty {
                    Text(ProfileGuide.description(key: edit.id.key)).font(FormMetrics.text).foregroundStyle(FleetStyle.muted)
                        .padding(.horizontal, FormMetrics.rowInset - 7).padding(.vertical, 10 - 7).allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // **The one look of a box of several lines** (`fleetTextBox`; fix round 3c, HIG): it kept a card's look —
            // a 1.39:1 edge, no ring with the cursor, room that took no click, and no stronger edge with Increase
            // Contrast — under a Title field in the field look.
            .fleetTextBox()
            .accessibilityLabel(edit.isNew ? String(l10n: "Rule text") : edit.name).accessibilityIdentifier("rule-text")
        // **Only while it has something to show** (the margins of 30 October 2026, row 32): empty, its line still took the
        // stack's 14 pt, and the box ended 38 pt over the window's bottom edge, where every page's last block ends 24 over it.
        let status = status(edit), deletes = !edit.isNew && edit.canDelete
        if status != nil || deletes {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let status {
                    Text(status.text).font(FormMetrics.detail).foregroundStyle(status.warning ? .orange : FleetStyle.muted)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("rule-status")
                }
                Spacer(minLength: 0)
                if deletes {
                    Button("Delete rule", role: .destructive) {
                        team.delete(key, store: store)
                        open(.agentDetail(agent, .behaviour))
                    }.buttonStyle(FleetDangerButtonStyle()).disabled(state == .saving)
                        .help("Removes this rule from the profile. New tasks do not get it.").accessibilityIdentifier("rule-delete")
                }
            }
        }
    }

    /// The one line under the text: the most important fact now, or nil.
    private func status(_ edit: ProfileSectionEdit) -> (text: String, warning: Bool)? {
        let typed = !edit.normalizedTitle.isEmpty || !edit.normalizedText.isEmpty
        if edit.isChanged, !edit.isNew || typed, let problem = edit.problem() { return (problem, true) }
        if let failure = state?.failure { return (String(l10n: "Not saved. \(failure)"), true) }
        if state == .behind { return nil }          // only Retry says it, with its reason on hover
        if state == .changedElsewhere { return (String(l10n: "Another change also changed this rule. This is its saved text now."), true) }
        if case .stale = team.reading { return (team.reading.lastReadingLine, true) }
        // Nothing while all is well (D-2): the save mark says Saved, and Add rule says what it does.
        return nil
    }

    /// Back to Behaviour. A changed rule saves first. A new rule that was not added stays for the next Add rule while it
    /// has text.
    private func close() {
        if let key, let edit {
            if !edit.isNew, edit.isChanged { team.save(key, store: store) }
            if edit.isNew, edit.normalizedTitle.isEmpty, edit.normalizedText.isEmpty { team.discard(key) }
        }
        open(.agentDetail(agent, .behaviour))
    }
}
