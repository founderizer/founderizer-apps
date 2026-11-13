import FleetCore
import SwiftUI

/// **The list that gives an agent its repositories** (owner feature `repo_picker`): the owner's yes of 9 November 2026 to
/// the list as shown, and of 11 November 2026 to its place ("Yes, under the heading"). The + on the GitHub heading of an
/// agent's Can use opens it under the heading, over the agent's own rows: every repository that the fleet's GitHub Apps
/// reach, by account (`GET /ui/github/repos`), with a search field; each account's name with how many of its
/// repositories the agent has or gets and a tick for all of them that the search shows; a tick at the right of each
/// repository, ticked and dimmed where the agent has it already; Read or Write for all of them; Cancel and Add N.
///
/// Add gives them in one change (`POST /ui/team/repos` with `agent` and `level`), so every other agent keeps its own.
/// **It sends only what the agent does not hold yet** in the reading it writes against: the hub sets each repository it
/// names to the level, so a repository that the agent got meanwhile, at Write, would come down to Read. The card and its
/// ticks stay until the hub has taken the write; a refusal, or a hub that did not answer, is one line in the card. The
/// new rows show in the agent's list.
///
/// The list was built for the agent's GitHub card in Founderizer 0.1.150, a card that no page had drawn since 18 October
/// 2026, so it never reached the screen. A hub without the feature keeps the + that lists what the fleet already holds
/// (`AccessGive`).
@MainActor @Observable
final class RepositoryPicking {
    /// The agent whose Can use has the list open, or nil.
    private(set) var openFor: String?
    var search = ""
    var picked: Set<String> = []
    var level: RepositoryAccess = .read
    /// The agent whose repositories are on their way to the hub, or nil.
    private(set) var givingFor: String?
    /// The list could not be read and none is kept: why, in a few words.
    private(set) var unread: String?
    /// What the hub said of the last Add while the list is open: its refusal, or that it did not answer.
    private(set) var said: String?

    /// The list, read when the + opens it: the store's (`FleetStore.reading`), so the one he saw last is there at once.
    static let listName = "github.repositories"
    /// **The list, read before it is needed** (`PagePrefetch`), on its own, since GitHub takes some seconds when the hub
    /// has not read it in the last minute (6 s on the owner's hub, 11 November 2026): the rows of Can use name each
    /// account as GitHub writes it from their first frame (`keepNames`), where they said "abccorp" for those
    /// seconds and then "AbcCorp", and the + opens on the list.
    static let prefetch = PagePrefetch(listName, feature: Integrations.pickerFeature, apart: true) { hub, database in
        try await IntegrationsClient().repositories(hub: hub, database: database)
    }
    /// A write that got no answer can still have arrived: the words of the request line for a write the hub did not
    /// confirm (`FleetView`). They hold here too, since the next Add sends only what the agent still does not hold.
    static let unanswered = String(l10n: "Your hub did not confirm it. Sending it again does not send it twice.")

    /// The hub has the list and the agent's own list to show its result in.
    static func offered(_ store: FleetStore) -> Bool {
        let features = store.state?.ui_features ?? []
        return features.contains(Integrations.pickerFeature) && features.contains(ResourceList.feature)
    }

    /// The repositories that an agent holds in a reading of Can use, at any level.
    static func held(_ reading: ResourceList?, agent: String) -> Set<String> {
        Set((reading?.resources ?? []).filter { $0.kind == "repo" && $0.holders.contains { $0.agent == agent } }.map(\.what))
    }

    func show(store: FleetStore, agent: String) {
        openFor = agent; search = ""; picked = []; level = .read; unread = nil; said = nil
        Task { await read(store) }
    }

    func close() { openFor = nil; search = ""; picked = []; said = nil }

    /// Every repository that the fleet's GitHub Apps reach, kept for this hub generation. A reading that could not read
    /// every App keeps the accounts that the one before it had (`RepositoryList.keeping`).
    private func read(_ store: FleetStore) async {
        guard let database = store.state?.db else { return }
        let hub = store.hub
        do {
            try await Self.keepList(store)
            unread = nil
        } catch {
            guard store.hub == hub, store.state?.db == database, (store.reading(Self.listName) as RepositoryList?) == nil
            else { return }
            if case HubError.refusal(_, let words) = error { unread = words } else { unread = String(l10n: "Founderizer cannot read GitHub now.") }
        }
    }

    /// One reading of the list into the store, shared with any other that is on its way (`FleetStore.read`).
    private static func keepList(_ store: FleetStore) async throws {
        guard let database = store.state?.db else { return }
        let hub = store.hub
        let list = try await store.read(listName) { try await IntegrationsClient().repositories(hub: hub, database: database) }
        guard store.hub == hub, store.state?.db == database else { return }
        store.keep(list.keeping(store.reading(listName)), as: listName)
    }

    /// **The accounts as GitHub writes them** ("AbcCorp", where team.json keeps "abccorp"), for the rows of
    /// Can use that hold an owner's repositories at one level (`AccessSettings`): the list, read once for this hub
    /// generation when none is kept. While it cannot be read, a row names the owner as team.json keeps it.
    static func keepNames(_ store: FleetStore) async {
        guard offered(store), (store.reading(listName) as RepositoryList?) == nil else { return }
        try? await keepList(store)
    }

    /// Gives the agent the ticked repositories that it does not hold yet, at the chosen level, in one write against the
    /// version of the team that its Can use read. When the team changed meanwhile (409), it reads it again and gives
    /// what the agent still does not hold, once more.
    func add(store: FleetStore, agent: String) async {
        guard givingFor == nil, let database = store.state?.db,
              var reading: ResourceList = store.reading(AccessSettings.name(agent)) else { return }
        let hub = store.hub, client = store.installation, choice = level
        var repos = picked.subtracting(Self.held(reading, agent: agent)).sorted()
        guard !repos.isEmpty else { return }
        givingFor = agent; said = nil
        defer { givingFor = nil }
        // An older line under the agent's rows says nothing of this Add.
        store.keep(nil as String?, as: AccessSettings.saidName(agent, kind: "repo"))
        var words: String?
        for attempt in 1...2 {
            do {
                _ = try await IntegrationsClient().giveRepositories(hub: hub, database: database, client: client,
                                                                    sha256: reading.sha256, repos: repos, agent: agent,
                                                                    access: choice)
                words = nil
                break
            } catch HubError.refusal(409, let refused) where attempt == 1 {
                guard let fresh = try? await AccessSettings.readResources(store, agent: agent, hub: hub, database: database)
                else { words = refused; break }
                reading = fresh
                repos = repos.filter { !Self.held(fresh, agent: agent).contains($0) }
                if repos.isEmpty { words = nil; break }
            } catch let HubError.refusal(_, refused) {
                words = refused
                break
            } catch is URLError {
                words = Self.unanswered
                break
            } catch {
                words = String(l10n: "The hub did not take this change. Try again.")
                break
            }
        }
        guard store.hub == hub, store.state?.db == database else { return }
        if words == nil {
            store.keep(nil as String?, as: AccessSettings.saidName(agent, kind: "repo"))
            if openFor == agent { close() }
        } else if openFor == agent {
            said = words
        } else {
            // The list was closed meanwhile: the line under the agent's rows, as for every + of Can use.
            store.keep(words, as: AccessSettings.saidName(agent, kind: "repo"))
        }
        if let fresh = try? await AccessSettings.readResources(store, agent: agent, hub: hub, database: database),
           store.hub == hub, store.state?.db == database {
            store.keep(fresh, as: AccessSettings.name(agent))
        }
    }
}

/// The + on the GitHub heading of an agent's Can use, with the list: it opens the list, and waits while the list's Add
/// goes to the hub. It is there once the agent's list is read and while the hub answers; what is left to give is the
/// list's to say, since what the GitHub Apps reach is read only when it opens.
struct RepositoryPickerPlus: View {
    @Bindable var store: FleetStore
    let agent: String
    let model: RepositoryPicking

    var body: some View {
        let reading: ResourceList? = store.reading(AccessSettings.name(agent))
        if model.givingFor == agent {
            ProgressView().controlSize(.small).frame(width: IconMetrics.side, height: IconMetrics.side)
                .padding(.trailing, FormMetrics.rowInset)
        } else if reading != nil, store.isFresh {
            IconButton(symbol: "plus", words: String(l10n: "Give \(agent.agentLabel) repositories")) { model.show(store: store, agent: agent) }
                .disabled(model.openFor == agent)
                // In the column of the rows' −, which stand the rows' inset in from the card's edge.
                .padding(.trailing, FormMetrics.rowInset)
                .accessibilityIdentifier("access-give-repo")
        }
    }
}

/// **The search row of a list of repositories**: each word in a repository's name without its owner
/// (`RepositoryList.Account.shown(by:)`). The list of Can use's + and the page of what a person may use of an agent
/// (`PersonAccessPage`) draw it.
struct RepositorySearch: View {
    @Binding var text: String
    var identifier = "agent-github-search"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(IconMetrics.symbol(14)).foregroundStyle(FleetStyle.muted).frame(width: 22)
                .padding(.trailing, 4).accessibilityHidden(true)
            TextField(text: $text, prompt: Text(verbatim: "")) { Text("Search") }
                .fieldPlaceholder(String(l10n: "Search"), shows: text.isEmpty).fleetField()
                .accessibilityIdentifier(identifier)
        }.padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 10)
    }
}

/// The list itself, a card under the GitHub heading (`RepositoryPicking`).
struct RepositoryPickerCard: View {
    @Bindable var store: FleetStore
    let agent: String
    @Bindable var model: RepositoryPicking

    /// The tallest the repositories stand before they scroll inside the card.
    private static let most: CGFloat = 360

    /// One account with the repositories of it that the search shows.
    private struct Shown: Identifiable {
        let account: RepositoryList.Account
        let repos: [String]
        var id: String { account.account }
    }

    private var list: RepositoryList? { store.reading(RepositoryPicking.listName) }

    var body: some View {
        let held = RepositoryPicking.held(store.reading(AccessSettings.name(agent)), agent: agent)
        let giving = model.picked.subtracting(held).count
        FormSection {
            RepositorySearch(text: $model.search)
            if let list {
                let accounts = list.accounts.map { Shown(account: $0, repos: $0.shown(by: model.search)) }.filter { !$0.repos.isEmpty }
                if accounts.isEmpty {
                    // As Knowledge says it of its filter.
                    FormEmpty("No repository matches the search.", symbol: "magnifyingglass")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(accounts) { shown in
                                if shown.id != accounts.first?.id { Rule().padding(.horizontal, FormMetrics.rowInset) }
                                accountRow(shown.account, shown: shown.repos, held: held)
                                Rule().padding(.horizontal, FormMetrics.rowInset)
                                ForEach(shown.repos, id: \.self) { repositoryRow($0, held: held.contains($0)) }
                            }
                        }
                        // The ticks wait while their write is on its way: the card closes when the hub has taken it.
                        .disabled(model.givingFor == agent)
                    }.frame(maxHeight: Self.most)
                }
                if let problem = list.problem { line(problem) }
            } else if let unread = model.unread {
                line(unread)
            } else {
                LoadingLine(String(l10n: "Reading GitHub…")).padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 10)
            }
            if let said = model.said { line(said).accessibilityIdentifier("agent-github-said") }
            HStack(spacing: 8) {
                FleetSegmented("Access of \(agent.agentLabel) to the repositories it gets", selection: $model.level,
                               options: [FleetOption(RepositoryAccess.read, "Read"), FleetOption(RepositoryAccess.write, "Write")])
                    .disabled(model.givingFor == agent)
                Spacer(minLength: 8)
                Button("Cancel") { model.close() }.buttonStyle(FleetOutlineButtonStyle())
                    .accessibilityIdentifier("agent-github-cancel")
                Button(giving == 0 ? "Add" : "Add \(giving)") { Task { await model.add(store: store, agent: agent) } }
                    .buttonStyle(FleetPrimaryButtonStyle())
                    .disabled(giving == 0 || !store.isFresh || model.givingFor != nil)
                    .accessibilityIdentifier("agent-github-add-picked")
            }.padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 10)
        }
    }

    /// One orange line of the card: what could not be read, or what the hub said of the last Add.
    private func line(_ words: String) -> some View {
        Text(words).font(FormMetrics.detail).foregroundStyle(.orange).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 10)
    }

    /// One account: its name as GitHub writes it, how many of its repositories the agent has or gets, and a tick for
    /// all of them that the search shows; ticked and dimmed, as their rows, when the agent has every one of them.
    private func accountRow(_ account: RepositoryList.Account, shown: [String], held: Set<String>) -> some View {
        let free = shown.filter { !held.contains($0) }
        return FormRow(account.account) {
            HStack(spacing: 10) {
                Text("\(account.chosen(held: held, picked: model.picked)) of \(account.repos.count)")
                    .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).monospacedDigit()
                Toggle("", isOn: Binding(get: { free.allSatisfy(model.picked.contains) },
                                         set: { on in if on { model.picked.formUnion(free) } else { model.picked.subtract(free) } }))
                    .labelsHidden().toggleStyle(FleetCheckboxStyle()).disabled(free.isEmpty)
                    .accessibilityLabel("Every repository of \(account.account)")
            }
        }.accessibilityIdentifier("agent-github-account-\(account.account)")
    }

    /// One repository: its name without its owner, and its tick, ticked and dimmed where the agent has it already.
    private func repositoryRow(_ repo: String, held: Bool) -> some View {
        HStack(spacing: 8) {
            Text(Integrations.name(repo)).font(FormMetrics.text).foregroundStyle(FleetStyle.text).lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 16)
            Toggle("", isOn: Binding(get: { held || model.picked.contains(repo) },
                                     set: { on in if on { model.picked.insert(repo) } else { model.picked.remove(repo) } }))
                .labelsHidden().toggleStyle(FleetCheckboxStyle()).disabled(held)
                .accessibilityLabel(repo)
        }
        .padding(.horizontal, FormMetrics.rowInset).frame(minHeight: FormMetrics.row)
        .opacity(held ? 0.55 : 1)
        .accessibilityIdentifier("agent-github-pick-\(repo)")
    }
}
