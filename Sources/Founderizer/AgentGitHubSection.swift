import FleetCore
import SwiftUI

/// One agent's GitHub (owner feature `integrations`), in its Integrations section: its repositories, each with Read,
/// Write or Deploy and Remove; Add repository; and each tool of the hub's catalog (the GitHub MCP server) as a switch.
/// Deploy needs the Workflows and Actions permissions on the hub's GitHub App, accepted on its installation. Each change
/// is one write against the team.json version that the section read (`POST /ui/team/repos` and `/ui/team/tools`, which
/// take every agent's access of one repository or one tool); on 409 the section reads it again and makes the same
/// change once more. The agent gets a change in its next task session, where its start text names its repositories.
struct AgentGitHubSection: View {
    let store: FleetStore
    let agent: String
    /// The fleet's integrations are the store's (`FleetStore.reading`), one reading of the whole fleet: what he read
    /// last shows in the first frame when he comes back, and the read that starts then changes only what changed.
    private var snapshot: IntegrationsSnapshot? {
        get { store.reading("integrations") } nonmutating set { store.keep(newValue, as: "integrations") }
    }
    @State private var readError: String?
    @State private var adding = false
    @State private var name = ""
    /// The list that gives this agent repositories (owner feature `repo_picker`; the owner's yes of 9 November 2026 to
    /// it as shown): every repository that the fleet's GitHub Apps reach, by account, a tick at the right of each, one
    /// level for all of them, and one Add.
    @State private var list: RepositoryList?
    @State private var listError: String?
    @State private var search = ""
    @State private var picked: Set<String> = []
    @State private var level: RepositoryAccess = .read
    /// The rows of an owner's repositories at one level that he opened (`Integrations.groups`).
    @State private var opened: Set<String> = []
    /// The change that waits for the hub, in words.
    @State private var busy: String?
    @State private var message: (text: String, warning: Bool)?
    /// The system's own words for the last change or read the hub did not answer: behind its line, never in it.
    @State private var cause: String?
    private let client = IntegrationsClient()

    private var label: String { agent.agentLabel }
    private var canChange: Bool { store.isFresh && busy == nil && snapshot != nil }
    private var picker: Bool { store.state?.ui_features?.contains(Integrations.pickerFeature) == true }
    /// This agent's repositories, with their access.
    private var holdings: [String: RepositoryAccess] { snapshot?.lines.first { $0.agent == agent }?.repos ?? [:] }
    /// An owner as GitHub writes it, once the list is read, and as team.json keeps it before.
    private func owner(_ owner: String) -> String { list?.accounts.first { $0.account.lowercased() == owner }?.account ?? owner }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                GitHubMark(size: 14).foregroundStyle(FleetStyle.text)
                Text("GitHub").font(FormMetrics.heading).foregroundStyle(FleetStyle.text)
            }.frame(minHeight: FormMetrics.headingRow).padding(.leading, 2)
                .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            // Before the first reading, the line alone: the GitHub App's section and the card come with it. While the
            // hub does not answer nothing is read, and the card says it cannot read the team in its place.
            if snapshot == nil && readError == nil && store.connectionError == nil {
                LoadingLine("Reading GitHub…")
            } else {
                if snapshot?.github?.app != true {
                    GitHubAppSection(store: store, app: snapshot?.github) { await read() }
                }
                FormSection(footer: "Each task session gets a one-hour token for these. It commits on the default branch "
                            + "and pushes — no branch, no pull request.") {
                    if let snapshot {
                        ForEach(Integrations.groups(holdings), id: \.id) { group in
                            if group.grouped {
                                groupRow(group)
                                if opened.contains(group.id) {
                                    ForEach(group.repos, id: \.self) { repositoryRow($0, group.access) }
                                }
                            } else {
                                ForEach(group.repos, id: \.self) { repositoryRow($0, group.access) }
                            }
                        }
                        if adding { if picker { pickerRows } else { addRow } } else {
                            FormRow(holdings.isEmpty ? "No repository yet" : "Another repository", symbol: "plus.circle",
                                    detail: "A repository that the hub's GitHub App is installed on.") {
                                Button("Add repository") {
                                    adding = true; message = nil; picked = []; search = ""; level = .read
                                    Task { await readList() }
                                }.buttonStyle(FleetOutlineButtonStyle()).disabled(!canChange)
                                    .accessibilityIdentifier("agent-github-add")
                            }
                        }
                        ForEach(snapshot.catalog, id: \.name) { toolRow($0.name, $0.tool, snapshot) }
                    } else if (readError != nil || store.connectionError != nil) && !store.hubNoticeShows {
                        // Not while the window's notice says the outage (`FleetStore.hubNoticeShows`; fix round 3,
                        // item 33: it is said once).
                        FormRow("Founderizer cannot read the team now.", detail: readError)
                            .help(behind(readError)).accessibilityValue(behind(readError))
                    }
                }
            }
            status
        }
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(agent)") {
            readError = nil; adding = false; name = ""; message = nil; picked = []; opened = []
            await read(since: .now)
            if !holdings.isEmpty { await readList() }       // the owners as GitHub writes them
        }
    }

    /// An owner's repositories at one level, when there are more than a few: the owner, their count and the level, in
    /// one row that opens to their own rows, where each keeps its level and its Remove.
    private func groupRow(_ group: RepositoryGroup) -> some View {
        let open = opened.contains(group.id)
        return FormRow(owner(group.owner), symbol: open ? "chevron.down" : "chevron.right") {
            HStack(spacing: 10) {
                Text("\(group.repos.count)").monospacedDigit()
                Text(group.access.title)
            }.font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
        }
        .contentShape(Rectangle())
        .onTapGesture { if open { opened.remove(group.id) } else { opened.insert(group.id) } }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(owner(group.owner)), \(group.repos.count) repositories, \(group.access.title)")
        .accessibilityIdentifier("agent-repositories-\(group.id)")
    }

    /// The list to choose from: a search field, each account's repositories under its name with a tick at the right,
    /// the level for all of them, Cancel and Add.
    @ViewBuilder private var pickerRows: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(IconMetrics.symbol(14)).foregroundStyle(FleetStyle.muted).frame(width: 22)
                .padding(.trailing, 4)
            TextField(text: $search, prompt: Text(verbatim: "")) { Text("Search") }
                .fieldPlaceholder("Search", shows: search.isEmpty).fleetField()
                .accessibilityIdentifier("agent-github-search")
        }.padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 10)
        if let list {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(list.accounts, id: \.account) { accountRows($0) }
                }
            }.frame(maxHeight: 360)
            if let problem = list.problem {
                Text(problem).font(FormMetrics.detail).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 6)
            }
        } else if let listError {
            Text(listError).font(FormMetrics.detail).foregroundStyle(.orange).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 10)
        } else {
            LoadingLine("Reading GitHub…").padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 10)
        }
        HStack(spacing: 8) {
            FleetSegmented("Access of \(label) to the repositories it gets", selection: $level,
                           options: [FleetOption(RepositoryAccess.read, "Read"), FleetOption(RepositoryAccess.write, "Write")])
            Spacer(minLength: 8)
            Button("Cancel") { adding = false; picked = []; search = "" }.buttonStyle(FleetOutlineButtonStyle())
            Button("Add \(picked.count)") { addPicked() }.buttonStyle(FleetPrimaryButtonStyle())
                .disabled(picked.isEmpty || !canChange).accessibilityIdentifier("agent-github-add-picked")
        }.padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 10)
    }

    /// One account in the list: its name, how many of its repositories the agent has or gets, and a tick for all of
    /// them that the search shows; then one row for each repository, ticked and dimmed where the agent has it already.
    @ViewBuilder private func accountRows(_ account: RepositoryList.Account) -> some View {
        let words = search.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = account.repos.filter { words.isEmpty || Integrations.name($0).contains(words) }
        let free = shown.filter { holdings[$0] == nil }
        let chosen = account.repos.filter { holdings[$0] != nil || picked.contains($0) }.count
        if !shown.isEmpty {
            FormRow(account.account) {
                HStack(spacing: 10) {
                    Text("\(chosen) of \(account.repos.count)").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                        .monospacedDigit()
                    Toggle("", isOn: Binding(get: { !free.isEmpty && free.allSatisfy(picked.contains) },
                                             set: { on in if on { picked.formUnion(free) } else { picked.subtract(free) } }))
                        .labelsHidden().toggleStyle(FleetCheckboxStyle()).disabled(free.isEmpty)
                        .accessibilityLabel("Every repository of \(account.account)")
                }
            }.fontWeight(.medium)
            ForEach(shown, id: \.self) { repo in
                let held = holdings[repo] != nil
                FormRow(Integrations.name(repo)) {
                    Toggle("", isOn: Binding(get: { held || picked.contains(repo) },
                                             set: { on in if on { picked.insert(repo) } else { picked.remove(repo) } }))
                        .labelsHidden().toggleStyle(FleetCheckboxStyle()).disabled(held)
                        .accessibilityLabel(repo)
                }.opacity(held ? 0.55 : 1).accessibilityIdentifier("agent-github-pick-\(repo)")
            }
        }
    }

    private func addPicked() {
        let repos = picked.sorted(), choice = level
        guard !repos.isEmpty else { return }
        let hub = store.hub, installation = store.installation, agent = agent, label = label
        let what = repos.count == 1 ? repos[0] : "\(repos.count) repositories"
        adding = false; picked = []; search = ""
        Task {
            await run("Giving \(label) \(choice.rawValue) access to \(what)…") { current, db in
                _ = try await client.giveRepositories(hub: hub, database: db, client: installation, sha256: current.sha256,
                                                      repos: repos, agent: agent, access: choice)
                return "\(label) gets \(choice.rawValue) access to \(what) in its next task session."
            }
        }
    }

    /// Reads the list that gives an agent repositories, from a hub that has it.
    private func readList() async {
        guard picker, let db = store.state?.db else { return }
        let hub = store.hub
        do {
            let fresh = try await client.repositories(hub: hub, database: db)
            guard store.hub == hub, store.state?.db == db else { return }
            list = fresh; listError = nil
        } catch {
            if list == nil { listError = Self.reason(error) }
        }
    }

    /// One repository: its name, its access (Read, Write or Deploy) and Remove.
    private func repositoryRow(_ repo: String, _ access: RepositoryAccess) -> some View {
        FormRow(repo, symbol: "shippingbox", detail: Self.words(access)) {
            HStack(spacing: 8) {
                FleetSelect("Access of \(label) to \(repo)",
                            selection: Binding(get: { access }, set: { choice in Task { await setAccess(repo, to: choice) } }),
                            options: [FleetOption(RepositoryAccess.read, "Read", subtitle: "Clone, fetch, and read issues and pull requests", mark: .symbol("eye")),
                                      FleetOption(RepositoryAccess.write, "Write", subtitle: "Also push branches and open pull requests", mark: .symbol("pencil")),
                                      FleetOption(RepositoryAccess.deploy, "Deploy", subtitle: "Also change its workflow files and run its Actions", mark: .symbol("arrow.up.circle"))])
                    .disabled(!canChange)
                MessageAction(symbol: "minus.circle", label: "Remove \(repo)", help: "Take \(repo) from \(label)") {
                    Task { await setAccess(repo, to: nil) }
                }.foregroundStyle(FleetStyle.muted).disabled(!canChange)
            }
        }.accessibilityIdentifier("agent-repository-\(repo)")
    }

    /// One level in the words of the row that carries it.
    private static func words(_ access: RepositoryAccess) -> String {
        switch access {
        case .read: return "Clones, fetches, and reads issues and pull requests"
        case .write: return "Reads it, pushes branches and opens pull requests"
        case .deploy: return "Also changes its workflow files and runs its Actions"
        }
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox").font(IconMetrics.symbol(15)).foregroundStyle(FleetStyle.text).frame(width: 22).padding(.trailing, 4)
            TextField(text: $name, prompt: Text(verbatim: "")) { Text("owner/name, for example acme/web") }
                .fieldPlaceholder("owner/name, for example acme/web", shows: name.isEmpty).fleetField()
                .onSubmit { add() }.accessibilityIdentifier("agent-github-name")
            Button("Add") { add() }.buttonStyle(FleetPrimaryButtonStyle()).disabled(Integrations.repository(name) == nil || !canChange)
            Button("Cancel") { adding = false; name = "" }.buttonStyle(FleetOutlineButtonStyle())
        }.padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 10)
    }

    /// One tool of Fleet's own catalog: a switch that gives it to this agent's task sessions or takes it back. The MCP
/// servers that the owner added are in `AgentMCPSection`.
    private func toolRow(_ tool: String, _ entry: IntegrationsSnapshot.Tool, _ snapshot: IntegrationsSnapshot) -> some View {
        let on = snapshot.agents(of: tool).contains(agent)
        let runtimes = entry.runtimes.map { ["claude": "Claude Code", "codex": "Codex"][$0] ?? $0.capitalized }
        return FormRow("\(entry.title) tools", symbol: "wrench.and.screwdriver",
                       detail: "The \(entry.title) MCP server in its \(runtimes.joined(separator: " and ")) task sessions, with the session's GitHub token") {
            Toggle("\(entry.title) tools for \(label)", isOn: Binding(get: { on }, set: { value in Task { await setTool(tool, on: value) } }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden().disabled(!canChange)
        }.accessibilityIdentifier("agent-tool-\(tool)")
    }

    private func add() {
        guard let repo = Integrations.repository(name) else { return }
        adding = false; name = ""
        Task { await setAccess(repo, to: .read) }
    }

    // MARK: changes

    @ViewBuilder private var status: some View {
        if let busy {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy) }
                .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).accessibilityIdentifier("agent-github-busy")
        } else if let message {
            Text(message.text).font(FormMetrics.detail).foregroundStyle(message.warning ? .orange : FleetStyle.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("agent-github-status")
                .help(behind(message.text)).accessibilityValue(behind(message.text))
        } else if let readError, snapshot != nil, !store.hubNoticeShows {
            // Not while the window's notice says the outage (`FleetStore.hubNoticeShows`).
            Text("Last reading. Founderizer cannot read the team now: \(readError)").font(FormMetrics.detail).foregroundStyle(.orange)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .help(behind(readError)).accessibilityValue(behind(readError))
        }
    }

    /// This agent's access to one repository; nil takes the repository from it. The other agents keep theirs.
    private func setAccess(_ repo: String, to choice: RepositoryAccess?) async {
        guard snapshot?.access(repo)[agent] != choice else { return }
        let hub = store.hub, installation = store.installation, agent = agent, label = label
        await run(choice.map { "Giving \(label) \($0.rawValue) access to \(repo)…" } ?? "Taking \(repo) from \(label)…") { current, db in
            _ = try await client.saveRepository(hub: hub, database: db, client: installation, sha256: current.sha256, repo: repo,
                                                access: Integrations.access(current.access(repo), agent: agent, to: choice))
            return choice.map { "\(label) gets \($0.rawValue) access to \(repo) in its next task session." } ?? "\(label) no longer gets \(repo)."
        }
    }

    private func setTool(_ tool: String, on: Bool) async {
        let hub = store.hub, installation = store.installation, agent = agent, label = label
        await run(on ? "Giving \(label) the tool \(tool)…" : "Taking the tool \(tool) from \(label)…") { current, db in
            let agents = Integrations.agents(current.agents(of: tool), agent: agent, on: on, order: current.lines.map(\.agent))
            _ = try await client.saveTool(hub: hub, database: db, client: installation, sha256: current.sha256, tool: tool, agents: agents)
            return on ? "\(label) gets \(tool) in its next task session." : "\(label) no longer gets \(tool)."
        }
    }

    /// One change at the hub against the team.json version that the section read: `busy` shows its words meanwhile.
    /// When the team changed meanwhile (409), the section reads it again and makes the same change on the new version.
    private func run(_ words: String, _ work: (IntegrationsSnapshot, String) async throws -> String) async {
        guard canChange, var current = snapshot, let db = store.state?.db else { return }
        let hub = store.hub
        busy = words; message = nil
        do {
            for attempt in 1...2 {
                do {
                    message = (try await work(current, db), false)
                    break
                } catch HubError.refusal(409, _) where attempt == 1 {
                    current = try await client.read(hub: hub, database: db)
                }
            }
        } catch { cause = Self.cause(error); message = (Self.reason(error), true) }
        busy = nil
        await read()
    }

    /// Reads the integrations. The first reading of a section that opened at `start` waits until a loading line that
    /// showed has stood half a second (`FleetStore.settle`).
    private func read(since start: ContinuousClock.Instant? = nil) async {
        guard store.state?.ui_features?.contains(Integrations.feature) == true, let db = store.state?.db else { return }
        let hub = store.hub
        let first = snapshot == nil
        do {
            let fresh = try await client.read(hub: hub, database: db)
            if first, let start { await store.settle(since: start) }
            guard store.hub == hub, store.state?.db == db else { return }
            snapshot = fresh; readError = nil
        } catch {
            if first, let start { await store.settle(since: start) }
            cause = Self.cause(error); readError = Self.reason(error)
        }
    }

    private static func reason(_ error: Error) -> String {
        if case HubError.refusal(_, let text) = error { return "Not done. The hub said: \(text.hasSuffix(".") ? text : text + ".")" }
        if error is URLError { return unanswered }
        return error.localizedDescription
    }

    /// A change or a read that the hub did not answer, in our words: the system's own are `cause`, on hover.
    private static let unanswered = "The hub did not answer. The change can still arrive: look at the list before you try again."
    private static func cause(_ error: Error) -> String? { error is URLError ? error.localizedDescription : nil }
    /// What stands behind a line: the system's words of an unanswered request, and nothing behind any other line.
    private func behind(_ line: String?) -> String { line == Self.unanswered ? cause ?? "" : "" }
}
