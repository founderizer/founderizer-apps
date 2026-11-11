import FleetCore
import SwiftUI

/// **"<agent> for <person>"** (the person access plan, owner feature `person_scope`; the owner's yes of 11 November 2026
/// to its mockup): what one person's conversations with one agent may use of what that agent holds. Only these… in the
/// agent's row of the person's Can talk to opens it, as a person's page opens from People, with the person as its way
/// back. Two groups, each with how many of the agent's own are in the list on its heading: **GitHub** — the picker's
/// search, each account as GitHub writes it, folded while nothing of it is in the list, and under an open one each
/// repository by its name, its level while it is ticked (never above the agent's own, and never deploy: Write is the
/// most) and its tick — and **Secrets**, a tick each (the conversation uses a secret only through the vault, so a new
/// tick is `use`).
///
/// The rows are what the agent holds now, as its Can use shows them. A resource of the list that the agent no longer
/// holds is not drawn, and the next write leaves it out, as the hub would refuse it. Each change writes this agent's
/// whole list at once (`POST /ui/people` `scopes`), as the person's other fields save themselves: the ticks show it in
/// the frame of the click, the writes go one at a time with the newest list, and a refusal shows the hub's list again,
/// with Try again on the group's heading and one orange line in the hub's words under its card. A list may be empty:
/// the person then talks with the agent, and gets no repository and no secret.
struct PersonAccessPage: View {
    @Bindable var store: FleetStore
    /// The person.
    let id: Int
    let agent: String
    let snapshot: PeopleSnapshot?
    let back: () -> Void
    /// Reads the people again.
    let changed: () async -> Void

    @State private var search = ""
    /// The accounts that are open, by owner; nil until the page has its rows, which open the accounts with a tick.
    @State private var open: Set<String>?
    /// The list as the owner set it here, until the hub's reading holds it (`settle`).
    @State private var draft: [String: String]?
    @State private var writing = false
    @State private var saving: SaveState?
    /// The group of the last change, `repo` or `secret`: where its save mark and its refusal stand.
    @State private var group = "repo"
    /// The list that the hub refused, which Try again sends.
    @State private var refused: [String: String]?
    @State private var problem: String?
    /// When this visit began: the resources' "Last reading" waits a second for the read on its way (`Held`).
    @State private var opened = ContinuousClock.now
    private let client = PeopleClient()

    /// One account of the agent's repositories, with those of them that the search shows.
    private struct Account: Identifiable {
        /// As team.json keeps it, in lower case.
        let owner: String
        /// As GitHub writes it.
        let name: String
        /// `owner/name`, by name.
        let repos: [String]
        var shown: [String] = []
        var id: String { owner }
    }

    /// One secret that the agent holds, by its name on the Secrets page.
    private struct Secret: Identifiable {
        let id: String
        let title: String
    }

    private var person: PeopleSnapshot.Person? { snapshot?.person(id) }
    private var scope: PersonScope? { person?.agents.first { $0.agent == agent }?.scope }
    private var offered: Bool { store.state?.ui_features?.contains(PersonScope.feature) == true }
    private var canWrite: Bool { store.isFresh && store.state?.db != nil }
    /// Nothing to set here any more: the person, their row of this agent, or its access is gone. The page goes back to
    /// the person's, which shows what is there now.
    private var gone: Bool { !offered || scope == nil }
    /// The agent's own Can use, or the fleet's reading of the same resources until the agent's own comes.
    private var reading: ResourceList? {
        store.reading(AccessSettings.name(agent)) ?? store.reading(AccessSettings.name(nil))
    }
    private var failed: Bool { store.reading(AccessSettings.name(agent) + ".failed") ?? false }
    /// The hub's list: what of it the agent holds now; nothing for All.
    private var hubList: [String: String] { scope?.list ?? [:] }
    /// The list that the ticks show.
    private var current: [String: String] { draft ?? hubList }

    var body: some View {
        FleetPage("\(People.agentWord(agent)) for \(person?.name ?? "Person")",
                  back: FleetBack(person?.name ?? "Person", action: back)) {
            if let reading {
                let holdings = reading.scopeHoldings(of: agent)
                github(holdings)
                secrets(reading, holdings: holdings)
            } else if failed || !store.isFresh {
                // Not while the window's notice says the outage, as Can use says it.
                if !store.hubNoticeShows {
                    FormSection {
                        FormRow("Founderizer cannot read the resources now.", detail: "It reads again when the hub answers.")
                    }
                }
            } else {
                LoadingLine("Reading the resources…")
            }
        }
        .font(FleetStyle.body).foregroundStyle(FleetStyle.text)
        .task(id: "\(store.hub)/\(store.state?.db ?? "")") { await poll() }
        .onChange(of: gone, initial: true) { _, gone in if gone { back() } }
        .onChange(of: reading != nil && scope != nil, initial: true) { _, ready in
            guard ready, open == nil, let reading else { return }
            let holdings = reading.scopeHoldings(of: agent)
            open = Set(current.keys.filter { PersonScope.kind(of: $0) == "repo" && holdings[$0] != nil }.map(Self.owner))
        }
        // A search opens every account that has a repository it shows.
        .onChange(of: search) { _, words in
            guard !words.isEmpty, let reading else { return }
            let matching = accounts(reading.scopeHoldings(of: agent)).filter { !$0.shown.isEmpty }.map(\.owner)
            open = (open ?? []).union(matching)
        }
        .onChange(of: hubList) { settle() }
        .onChange(of: writing) { settle() }
    }

    // MARK: GitHub

    /// The agent's repositories by account, in the order of Can use: by owner, each account's by name.
    private func accounts(_ holdings: [String: String]) -> [Account] {
        let list: RepositoryList? = store.reading(RepositoryPicking.listName)
        let repos = holdings.keys.filter { PersonScope.kind(of: $0) == "repo" }.map { String($0.dropFirst("repo:".count)) }
        return Dictionary(grouping: repos) { String($0.prefix { $0 != "/" }) }
            .map { owner, repos in
                let sorted = repos.sorted()
                let name = list?.account(owner) ?? owner
                return Account(owner: owner, name: name, repos: sorted,
                               shown: RepositoryList.Account(account: name, repos: sorted).shown(by: search))
            }
            .sorted { $0.owner < $1.owner }
    }

    @ViewBuilder private func github(_ holdings: [String: String]) -> some View {
        let accounts = accounts(holdings)
        let shown = accounts.filter { !$0.shown.isEmpty }
        let list = current
        let all = accounts.reduce(0) { $0 + $1.repos.count }
        let ticked = list.keys.filter { PersonScope.kind(of: $0) == "repo" && holdings[$0] != nil }.count
        VStack(alignment: .leading, spacing: FleetSpace.inside) {
            // Only the rows on the screen: an account can hold 179 repositories (`FormSection.lazy`).
            FormSection("GitHub", lazy: true) {
                if accounts.isEmpty {
                    FormEmpty("No repositories", symbol: AccessSettings.symbol("repo"))
                } else {
                    RepositorySearch(text: $search, identifier: "person-access-search")
                    // As the picker says it of its search.
                    if shown.isEmpty { FormEmpty("No repository matches the search.", symbol: "magnifyingglass") }
                    ForEach(shown) { account in
                        accountRow(account, list: list, holdings: holdings)
                        if open?.contains(account.owner) == true {
                            ForEach(account.shown, id: \.self) { repositoryRow($0, list: list, holdings: holdings) }
                        }
                    }
                }
            } accessory: {
                AccessSettings.lastReading(store, agent: agent, since: opened)
                SaveMark(state: group == "repo" ? saving : nil, retry: retry)
                if all > 0 { count(ticked, of: all) }
            }
            if group == "repo", let problem { line(problem) }
        }
    }

    /// **One account**: its name as GitHub writes it, how many of its repositories are in the list, and a tick for all
    /// of them that the search shows. A click opens it to its repositories and folds it again, as an account's row of
    /// Can use does; the tick stands over the row, so that its click is its own.
    private func accountRow(_ account: Account, list: [String: String], holdings: [String: String]) -> some View {
        let isOpen = open?.contains(account.owner) == true
        let tickable = account.shown.filter { !PersonScope.levels("repo", agentHas: holdings["repo:\($0)"] ?? "").isEmpty }
        let ticked = account.repos.filter { list["repo:\($0)"] != nil }.count
        return Button { fold(account.owner) } label: {
            HStack(spacing: 0) {
                RowMark {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(IconMetrics.symbol(11, weight: .semibold))
                        .foregroundStyle(FleetStyle.muted)
                }
                Text(account.name).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                count(ticked, of: account.repos.count)
                // The room of the tick, which stands over the row.
                Color.clear.frame(width: IconMetrics.side, height: IconMetrics.side).padding(.leading, 10)
            }
            .padding(.horizontal, FormMetrics.rowInset).frame(minHeight: FormMetrics.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(FleetRowButtonStyle())
        .help(isOpen ? "Hide these repositories" : "Show these repositories")
        .accessibilityLabel("\(account.name), \(ticked) of \(account.repos.count)")
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("person-access-account-\(account.owner)")
        .overlay(alignment: .trailing) {
            Toggle("", isOn: Binding(get: { !tickable.isEmpty && tickable.allSatisfy { list["repo:\($0)"] != nil } },
                                     set: { on in
                                         change("repo") { next in
                                             for repo in tickable {
                                                 let id = "repo:\(repo)"
                                                 if !on { next[id] = nil } else if next[id] == nil { next[id] = "read" }
                                             }
                                         }
                                     }))
                .labelsHidden().toggleStyle(FleetCheckboxStyle()).disabled(!canWrite || tickable.isEmpty)
                .accessibilityLabel("Every repository of \(account.name)")
                .padding(.trailing, FormMetrics.rowInset)
        }
    }

    /// **One repository**: its name without its owner, its level while it is ticked — a select of the levels up to the
    /// agent's own, or the one level as a value — and its tick. A new tick is Read, the lowest, as every give of the app.
    private func repositoryRow(_ repo: String, list: [String: String], holdings: [String: String]) -> some View {
        let id = "repo:\(repo)"
        let has = holdings[id] ?? ""
        let levels = PersonScope.levels("repo", agentHas: has)
        let level = list[id].flatMap { PersonScope.level($0, kind: "repo", agentHas: has) }
        return HStack(spacing: 8) {
            Text(Integrations.name(repo)).font(FormMetrics.text).foregroundStyle(FleetStyle.text).lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 16)
            if let level {
                if levels.count < 2 {
                    // One level is a value, not a choice (fix round 3c): an agent at Read offers Read only.
                    Text(AccessSettings.levelName(level, kind: "repo")).font(FormMetrics.text).foregroundStyle(FleetStyle.muted)
                } else {
                    FleetSelect("What \(person?.name ?? "this person")'s conversations may do with \(repo)",
                                options: levels.map { FleetOption($0, AccessSettings.levelName($0, kind: "repo")) },
                                selection: level) { chosen in change("repo") { $0[id] = chosen } } label: {
                        FleetSelectLabel(title: AccessSettings.levelName(level, kind: "repo"))
                    }
                    .disabled(!canWrite)
                    .accessibilityIdentifier("person-access-level-\(repo)")
                }
            }
            Toggle("", isOn: Binding(get: { level != nil }, set: { on in change("repo") { $0[id] = on ? levels.first : nil } }))
                .labelsHidden().toggleStyle(FleetCheckboxStyle()).disabled(!canWrite || levels.isEmpty)
                .accessibilityLabel(repo)
        }
        // Its name where the account's name begins, after the chevron's column.
        .padding(.leading, FormMetrics.rowInset + FormMetrics.markColumn + FormMetrics.markGap)
        .padding(.trailing, FormMetrics.rowInset)
        .frame(minHeight: FormMetrics.row)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("person-access-repo-\(repo)")
    }

    // MARK: Secrets

    @ViewBuilder private func secrets(_ reading: ResourceList, holdings: [String: String]) -> some View {
        // By name, as the Secrets page sorts them.
        let secrets = holdings.keys.filter { PersonScope.kind(of: $0) == "secret" }
            .map { Secret(id: $0, title: reading.resource($0)?.title ?? String($0.dropFirst("secret:".count))) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let list = current
        let ticked = secrets.filter { list[$0.id] != nil }.count
        VStack(alignment: .leading, spacing: FleetSpace.inside) {
            FormSection("Secrets") {
                if secrets.isEmpty { FormEmpty("No secrets", symbol: AccessSettings.symbol("secret")) }
                ForEach(secrets) { secret in
                    FormRow(secret.title) {
                        Toggle("", isOn: Binding(get: { list[secret.id] != nil },
                                                 set: { on in change("secret") { $0[secret.id] = on ? "use" : nil } }))
                            .labelsHidden().toggleStyle(FleetCheckboxStyle()).disabled(!canWrite)
                            .accessibilityLabel(secret.title)
                    }
                    .accessibilityIdentifier("person-access-secret-\(secret.id)")
                }
            } accessory: {
                SaveMark(state: group == "secret" ? saving : nil, retry: retry)
                if !secrets.isEmpty { count(ticked, of: secrets.count) }
            }
            if group == "secret", let problem { line(problem) }
        }
    }

    // MARK: the words

    /// "N of M": how many of the agent's own are in the list.
    private func count(_ chosen: Int, of all: Int) -> some View {
        Text("\(chosen) of \(all)").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).monospacedDigit()
    }

    /// The one orange line under a group's card: the hub's words of the write that it refused.
    private func line(_ words: String) -> some View {
        Text(words).font(FormMetrics.detail).foregroundStyle(.orange).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("person-access-problem")
    }

    /// The owner of a repository's resource, `repo:<owner>/<name>`.
    private static func owner(_ resource: String) -> String {
        String(resource.dropFirst("repo:".count).prefix { $0 != "/" })
    }

    private func fold(_ owner: String) {
        var now = open ?? []
        if now.contains(owner) { now.remove(owner) } else { now.insert(owner) }
        open = now
    }

    // MARK: saving

    /// **One change of the list, in the frame of the click**: the ticks show the new list at once, and it goes to the
    /// hub after the write that is on its way, if one is.
    private func change(_ group: String, _ edit: (inout [String: String]) -> Void) {
        guard canWrite else { return }
        var next = current
        edit(&next)
        guard next != current else { return }
        draft = next
        self.group = group
        refused = nil
        Task { await send() }
    }

    /// **The writes go one at a time, each with the newest list**: a change made while one is on its way goes after it.
    /// The hub sets the list of this agent alone. A refusal shows the hub's list again, and Try again sends the refused
    /// one.
    private func send() async {
        guard !writing else { return }
        writing = true
        defer { writing = false }
        var took: [String: String]?
        while let want = draft, want != took {
            guard canWrite, let db = store.state?.db, let reading else { draft = nil; saving = nil; return }
            saving = .saving; problem = nil
            do {
                _ = try await client.scope(hub: store.hub, database: db, client: store.installation, person: id, agent: agent,
                                           list: PersonScope.written(want, holdings: reading.scopeHoldings(of: agent)))
                took = want
            } catch {
                let words = People.reason(error)
                saving = .failed(words); problem = words; refused = want; draft = nil
                await changed()
                return
            }
            // The hub's own reading, so that the ticks show what it holds (`settle`), unless a newer change goes first.
            if draft == took { await changed() }
        }
        if took != nil {
            saving = .saved
            markSaved()
        }
    }

    /// **The hub's reading holds the list that went**: the ticks show the hub's own list again, so that a change made
    /// elsewhere shows too. It waits while a write is on its way.
    private func settle() {
        guard !writing, let draft, let reading else { return }
        if PersonScope.written(draft, holdings: reading.scopeHoldings(of: agent)) == hubList { self.draft = nil }
    }

    /// Try again: the list that the hub refused.
    private func retry() {
        guard let refused else { return }
        draft = refused
        self.refused = nil
        Task { await send() }
    }

    /// "Saved" stays for a moment, as every other control that saves itself.
    private func markSaved() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            if saving == .saved { saving = nil }
        }
    }

    /// The agent's resources every 15 seconds while the page shows, as its Can use reads them, and the accounts as
    /// GitHub writes them, once for this hub generation.
    private func poll() async {
        opened = .now
        let start = ContinuousClock.now
        var named = false
        while !Task.isCancelled {
            let read = await AccessSettings.readOnce(store, agent: agent, since: start)
            if !named { named = true; await RepositoryPicking.keepNames(store) }
            do { try await store.nap(read ? 15 : 3) } catch { return }
        }
    }
}
