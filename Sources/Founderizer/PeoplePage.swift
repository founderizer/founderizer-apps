import FleetCore
import SwiftUI

/// People (UI-API.md 1.17, owner features `people` and `conversations`): who may talk to your agents, and everyone
/// who tried and was dropped. Only the owner writes a person; the hub keeps that rule and this page does not pretend
/// otherwise.
///
/// Two cards. **People**: one row for each person — their name, their role, the agents they reach, and the one thing
/// that stops them. A click opens the person. **Wrote and was not answered**: the senders the hub dropped, newest
/// first, each with Add, which opens the form with that handle already in it. That is the whole path from "somebody
/// tried to reach my agent" to "they can". On the fleet's own page, once contacts.v2 is on, **Roles** (plan P1, the
/// owner's yes of 27 October 2026): one row for each role, which opens it (`RolePage`).
///
/// The person, the form, a conversation and a role open in place of the list, each with a back link, as every other
/// sub-page does. The page reads `GET /ui/people` (and `GET /ui/roles`) every 5 seconds while it shows.
struct PeoplePage: View {
    @Bindable var store: FleetStore
    /// One agent's page: the people who may reach that agent, and nobody else. nil is the fleet's own list.
    var agent: String?
    /// **A group of the agent's People** (D-5): the people who can talk to it under their heading, read-only — a person
    /// is added in Settings › People, the one editor of the kind — and the empty card when there is nobody (the owner,
    /// 3 November 2026, of an agent's groups: "show like an empty card or something, like in other places of the app").
    var grouped = false
    /// The person or the conversation that shows, kept by the part around this group, which shows it in its own place
    /// (`AgentPeoplePart`): nil keeps it here.
    var routeBinding: Binding<[Route]>? = nil
    /// The readings are the store's (`FleetStore.reading`), the fleet's and each agent's under its own name: the people
    /// he saw last show in the first frame when he comes back, and the read that starts then changes only what changed.
    private var reading: PeopleReading<PeopleSnapshot> {
        get { store.reading(peopleName) ?? .loading } nonmutating set { store.keep(newValue, as: peopleName) }
    }
    /// The fleet's roles (plan P1, owner feature `contact_roles`), read with the people on the fleet's own page.
    private var roleReading: PeopleReading<RoleList> {
        get { store.reading(Self.rolesName) ?? .loading } nonmutating set { store.keep(newValue, as: Self.rolesName) }
    }
    @State private var ownRoute: [Route] = []
    private var route: [Route] {
        get { routeBinding?.wrappedValue ?? ownRoute }
        nonmutating set { if let routeBinding { routeBinding.wrappedValue = newValue } else { ownRoute = newValue } }
    }
    @State private var problem: String?
    /// When this visit began: a line about a kept reading waits a second for the read that is on its way (`Held`).
    @State private var opened = ContinuousClock.now
    private let client = PeopleClient()
    private var peopleName: String { "people.list.\(agent ?? "fleet")" }
    private static let rolesName = "people.roles.fleet"
    /// The people and the roles, read before the page first opens (`PagePrefetch`): the fleet's, and each agent's.
    static let prefetch = PagePrefetch("people.list.fleet", feature: People.feature) {
        PeopleReading.current(try await PeopleClient().people(hub: $0, database: $1), at: Date().timeIntervalSince1970)
    }
    static let rolesPrefetch = PagePrefetch(rolesName, feature: RoleList.feature) {
        PeopleReading.current(try await PeopleClient().roles(hub: $0, database: $1), at: Date().timeIntervalSince1970)
    }
    static let agentPrefetch = PagePrefetch(agent: { "people.list.\($0)" }, feature: People.feature) { hub, database, _ in
        PeopleReading.current(try await PeopleClient().people(hub: hub, database: database), at: Date().timeIntervalSince1970)
    }

    init(store: FleetStore, agent: String? = nil, grouped: Bool = false, route: Binding<[Route]>? = nil) {
        self.store = store; self.agent = agent; self.grouped = grouped; self.routeBinding = route
    }

    enum Route: Hashable {
        case add(app: String?, handle: String?, name: String?)
        case person(Int)
        /// What one person may use of one agent of their list ("<agent> for <person>"), from the person's page.
        case access(person: Int, agent: String)
        case conversation(Int)
        case role(String)
    }

    private var people: [PeopleSnapshot.Person] {
        let all = reading.value?.peopleList ?? []
        guard let agent else { return all }
        return all.filter { person in person.agents.contains { $0.agent == agent } }
    }
    private var roles: [PeopleSnapshot.Role] { reading.value?.roleList ?? [] }
    private var now: Double { store.state?.time ?? Date().timeIntervalSince1970 }
    private var offered: Bool { store.state?.ui_features?.contains(People.feature) == true }
    /// The roles are the fleet's, so only the fleet's own page has them, and only after the switch (`RoleList.feature`).
    private var offersRoles: Bool { agent == nil && store.state?.ui_features?.contains(RoleList.feature) == true }
    private var canWrite: Bool { store.isFresh && store.state?.db != nil }

    var body: some View {
        Group {
            switch route.last {
            case .add(let app, let handle, let name):
                // From one agent's People the person reaches that agent, so the wizard does not ask who (the owner,
                // 28 October 2026). The fleet's limit counts every person, not this agent's.
                AddPersonView(store: store, roles: roles, existing: reading.value?.peopleList.count ?? 0,
                              handle: app.map { app in
                                  var one = PersonInput.HandleInput.exact(app: app, handle: handle ?? "")
                                  one.name = name ?? ""
                                  return one
                              },
                              agent: agent,
                              back: { route.removeLast() },
                              added: { person in route = [.person(person)]; Task { await read() } })
            case .person(let id):
                PersonPage(store: store, id: id, snapshot: reading.value, back: { route.removeLast() },
                           changed: { await read() },
                           removed: { route = []; Task { await read() } },
                           open: { route.append(.conversation($0)) },
                           openAccess: { route.append(.access(person: id, agent: $0)) })
            case .access(let id, let agent):
                PersonAccessPage(store: store, id: id, agent: agent, snapshot: reading.value, back: { route.removeLast() },
                                 changed: { await read() })
            case .conversation(let id):
                ConversationPage(store: store, id: id, backTitle: backTitle, back: { route.removeLast() })
            case .role(let name):
                // A hub that stopped listing the roles (the switch went off) shows the list in place of the role.
                if offersRoles {
                    RolePage(store: store, name: name, roles: roleReading.value, back: { route.removeLast() },
                             changed: { await read() },
                             renamed: { new in if case .role? = route.last { route[route.count - 1] = .role(new) } })
                } else {
                    list
                }
            case nil:
                list
            }
        }
        .font(FleetStyle.body).foregroundStyle(FleetStyle.text)
        .task(id: "\(store.hub)/\(store.state?.db ?? "")") {
            // The part's person stays open: this view is made again as it opens and closes.
            if routeBinding == nil { ownRoute = [] }
            problem = nil
            let start = ContinuousClock.now
            while !Task.isCancelled {
                await read(since: start)
                do { try await store.nap(5) } catch { return }
            }
        }
    }

    /// No reading of the page yet: the people, and on the fleet's own page the roles too, so its cards come in one frame.
    private var waits: Bool {
        if case .loading = reading { return true }
        if offersRoles, case .loading = roleReading { return true }
        return false
    }

    /// A line about a kept reading that the read on its way can take away: held for its second (`Held`).
    @ViewBuilder private func held(_ name: String, @ViewBuilder _ line: () -> some View) -> some View {
        if store.readingWaits(name, since: opened) { Held(since: opened) { line() } } else { line() }
    }

    private var backTitle: String {
        if case .person(let id)? = route.dropLast().last { return people.first { $0.id == id }?.name ?? "Person" }
        return "People"
    }

    // MARK: the list

    @ViewBuilder private var list: some View {
        if grouped { group } else { page }
    }

    /// The people who can talk to this agent, as a group of its People part: the heading and the rows, or the empty
    /// card, and the reading's own lines.
    private var group: some View {
        VStack(alignment: .leading, spacing: FleetSpace.block) {
            FormSection("People") {
                if offered, let value = reading.value, value.hasPeople {
                    ForEach(people) { row($0) }
                    // The words of the agent's other empty groups ("No secrets", "No number"): no "yet" on an agent's page.
                    if people.isEmpty { FormEmpty("No people", symbol: "person.2") }
                }
            }
            if offered, reading.value == nil {
                if case .loading = reading, store.connectionError == nil { LoadingLine("Reading the people…") } else { readingRow }
            }
            statusLine
        }
    }

    private var page: some View {
        FleetPage("People") {
            Group {
                if offered, reading.value?.hasPeople == false {
                    FormSection {
                        FormRow("The hub does not serve people yet", symbol: "exclamationmark.circle",
                                warning: "Update the hub to UI-API 1.17.")
                    }
                } else if !offered {
                    FormSection { FormRow("Your hub has no People yet", symbol: "person.2.slash") }
                } else if waits, store.connectionError == nil {
                    // The first visit: nothing of the list until it is read, then all of its cards in one frame. While
                    // the hub does not answer nothing is read, and the failed row stands in its place.
                    LoadingLine("Reading the people…")
                } else if reading.value == nil {
                    readingRow
                } else {
                    FormSection {
                        ForEach(people) { row($0) }
                        if people.isEmpty {
                            // The fleet's own lists say "yet"; an agent's groups do not ("No people", "No secrets").
                            FormEmpty("No people yet", symbol: "person.2")
                        }
                    }
                    if agent == nil { strangers }
                    roleCard
                }
                statusLine
            }
        } actions: {
            // With its plus, as Add server, Add agent and Add secret have theirs.
            // The roles to choose from are the hub's, so the wizard opens once they are read: a press that comes
            // before the first reading waits for it.
            Button { Task { await add() } } label: { Label("Add person", systemImage: "plus") }
                .buttonStyle(FleetPrimaryButtonStyle()).disabled(!canWrite || !offered)
                .accessibilityIdentifier("people-add")
        }
    }

    private func add() async {
        if roles.isEmpty { await read() }
        guard !roles.isEmpty else { return }
        route.append(.add(app: nil, handle: nil, name: nil))
    }

    /// One person: their name, their role and the agents they reach, and one mark for whether they can talk to
    /// them at all.
    ///
    /// The whole row is already one button that opens the person, so the mark cannot be `StateMark` — a button
    /// inside a button reaches neither the keyboard nor VoiceOver. It is the mark's shape and colour, and the
    /// sentence this row used to print as a third line is behind it: on the pointer, and off the row itself for a
    /// reader. The name and the role are values, so they keep their words.
    private func row(_ person: PeopleSnapshot.Person) -> some View {
        let state = person.state(now: now)
        return Button { route.append(.person(person.id)) } label: {
            HStack(spacing: 12) {
                IconTile(symbol: "person.crop.circle")
                VStack(alignment: .leading, spacing: 3) {
                    Text(person.name).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(1)
                    Text("\(person.roleWord) · \(People.agentWords(person.agentNames))")
                        .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                }
                Spacer(minLength: 12)
                ForEach(person.apps, id: \.self) { BrandMark(app: $0, size: 13).foregroundStyle(FleetStyle.muted) }
                // Last before the chevron: one person writes from two apps and the next from one, so anything
                // further left would put this row's mark at a different place from the one above it.
                RowStateMark(state: person.mark(now: now)).accessibilityIdentifier("person-state-\(person.id)")
                Image(systemName: "chevron.right").font(IconMetrics.symbol(11, weight: .semibold)).foregroundStyle(FleetStyle.muted)
            }
            .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 11).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(FleetRowButtonStyle())
        .help(state.words)
        .accessibilityLabel(person.name)
        .accessibilityValue("\(person.roleWord). \(People.agentWords(person.agentNames)). \(state.words)")
        .accessibilityIdentifier("person-\(person.id)")
    }

    /// The fleet's roles (plan P1): one row for each, its name, what the agent is told about such a person, and a mark
    /// for its one switch — the agent's own tools, or closed — with the words behind it. A click opens the role.
    @ViewBuilder private var roleCard: some View {
        if offersRoles {
            if let roles = roleReading.value?.roles, !roles.isEmpty {
                FormSection("Roles") { ForEach(roles) { roleRow($0) } }
            } else if let why = roleReading.failure {
                held(Self.rolesName) {
                    // Not while the window's notice says the outage (`FleetStore.hubNoticeShows`): the card keeps its
                    // heading alone.
                    FormSection("Roles") {
                        if !store.hubNoticeShows {
                            FormRow("The roles are unavailable", symbol: "exclamationmark.circle", warning: why)
                                .accessibilityIdentifier("roles-failed")
                        }
                    }
                }
            }
        }
    }

    private func roleRow(_ role: RoleList.Role) -> some View {
        let switched = role.tools ? "With the agent's tools" : "Closed, without the agent's tools"
        return Button { route.append(.role(role.name)) } label: {
            HStack(spacing: 12) {
                IconTile(symbol: role.tools ? "wrench.and.screwdriver" : "lock")
                VStack(alignment: .leading, spacing: 3) {
                    Text(role.word).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(1)
                    Text(People.oneLine(role.prompt)).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right").font(IconMetrics.symbol(11, weight: .semibold)).foregroundStyle(FleetStyle.muted)
            }
            .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 11).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(FleetRowButtonStyle())
        .help(switched)
        .accessibilityLabel(role.word)
        .accessibilityValue("\(switched). \(role.prompt)")
        .accessibilityIdentifier("role-\(role.name)")
    }

    /// Everyone who wrote to an account of this fleet and got no answer, newest first. Your agents answer you and the
    /// people you added; everybody else is dropped. Add makes one of them a person, with their handle already in.
    @ViewBuilder private var strangers: some View {
        let waiting = reading.value?.strangers ?? []
        if !waiting.isEmpty {
            FormSection("Wrote and was not answered") {
                ForEach(waiting) { stranger($0) }
            }
        }
    }

    private func stranger(_ item: PeopleSnapshot.Stranger) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !item.app.isEmpty { BrandMark(app: item.app, size: 12).foregroundStyle(FleetStyle.muted) }
                Text(item.message.who).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(1)
                Text(activityAge(item.message.ts, now: now)).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                Spacer(minLength: 8)
                Button("Add") {
                    route.append(.add(app: item.app, handle: item.message.sender, name: item.message.name))
                }
                .buttonStyle(FleetOutlineButtonStyle()).disabled(!canWrite || item.message.sender == nil)
                .help("Add them as a person, so \(item.agent.map(People.agentWord) ?? "your agent") can answer.")
                .accessibilityIdentifier("stranger-add-\(item.id)")
            }
            if let said = item.message.said {
                Text(said).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 10)
        .accessibilityElement(children: .contain).accessibilityIdentifier("stranger-\(item.id)")
    }

    @ViewBuilder private var readingRow: some View {
        // Not while the window's notice says the outage (`FleetStore.hubNoticeShows`; fix round 3, item 33).
        if (reading.failure != nil || store.connectionError != nil) && !store.hubNoticeShows {
            held(peopleName) {
                FormSection {
                    FormRow("The people are unavailable", symbol: "exclamationmark.circle", warning: reading.failure)
                        .accessibilityIdentifier("people-failed")
                }
            }
        }
    }

    /// One line at a time: this page's own refusal first, then an old reading.
    @ViewBuilder private var statusLine: some View {
        if let problem {
            Text(problem).font(FormMetrics.detail).foregroundStyle(.orange).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("people-problem")
        } else if reading.isOld && !store.hubNoticeShows {
            // Not while the window's notice says the outage (fix round 3c; item 33: an outage is said once).
            held(peopleName) {
                Text("Last reading \(activityAge(reading.at, now: now).lowercased()). Founderizer reads again every 5 seconds.")
                    .font(FormMetrics.detail).foregroundStyle(.orange).accessibilityIdentifier("people-stale")
            }
        }
    }

    // MARK: the hub

    /// The people and, on the fleet's own page, the roles, kept together: a first reading draws its cards in one frame.
    private func read(since start: ContinuousClock.Instant? = nil) async {
        guard offered, let db = store.state?.db else { return }
        let hub = store.hub, first = waits
        let people: PeopleReading<PeopleSnapshot>
        do {
            people = .current(try await client.people(hub: hub, database: db), at: now)
        } catch {
            people = reading.aged ?? .failed(People.reason(error))
        }
        var roles: PeopleReading<RoleList>?
        if offersRoles {
            do {
                roles = .current(try await client.roles(hub: hub, database: db), at: now)
            } catch {
                roles = roleReading.aged ?? .failed(People.reason(error))
            }
        }
        if first, let start { await store.settle(since: start) }
        guard store.hub == hub, store.state?.db == db else { return }
        reading = people
        if let roles { roleReading = roles }
    }
}
