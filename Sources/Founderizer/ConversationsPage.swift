import FleetCore
import SwiftUI

/// Conversations (UI-API.md 1.17, owner feature `conversations`): every conversation between one of your agents and
/// a person, newest first. This is the half the owner asked for twice — he reads every word, and what the agent did
/// about it.
///
/// One row for each: who talked to which agent, the last thing that was said, and what needs him. Two dropdowns
/// narrow it, the agent and the person. A click opens the conversation in place, with a back link. The page reads
/// `GET /ui/conversations` every 5 seconds while it shows.
///
/// **In an agent's People, its conversations with the other agents stand beside the people's** (the owner, 6 November
/// 2026: "conversations between the agent and other agents should appear under Conversations section (inside people)",
/// and his yes to the mockup the same day): one row for each agent it wrote to or heard from, read out of
/// `GET /ui/agent-messages` (`AgentConversation`), newest first among the people's. A row opens the two agents' chat
/// (`AgentConversationPage`). Nothing in it waits for him, so its row has no mark, and its age stands in the column of
/// the others'.
struct ConversationsPage: View {
    @Bindable var store: FleetStore
    /// The agent whose page this is: its conversations and no other agent's.
    var scope: String
    /// **The last group of the agent's People** (D-5): the conversations under their heading, the person filter on it
    /// while there are some or a person is chosen, and the empty card when there are none (the owner, 3 November 2026: "show like an empty
    /// card or something, like in other places of the app").
    var grouped = false
    /// The agent holds conversations with people: a worker or a lead. The manager's group has its conversations with
    /// the other agents only, and no person filter.
    var people = true
    /// The open conversation, kept by the part around this group, which shows it in its own place (`AgentPeoplePart`).
    var openBinding: Binding<Int?>? = nil
    /// The other agent whose chat with this one is open, kept by the part around this group, as `openBinding` is.
    var openAgentBinding: Binding<String?>? = nil
    /// All of this agent's conversations, as the page read them last: the store's (`FleetStore.reading`), so they show
    /// in the first frame when he comes back. A reading of one person's is this visit's own (`narrowed`).
    private var all: PeopleReading<[Conversation]> {
        get { store.reading(listName) ?? .loading } nonmutating set { store.keep(newValue, as: listName) }
    }
    @State private var narrowed: PeopleReading<[Conversation]>?
    /// The people, for the dropdown: the store's too.
    private var peopleList: PeopleSnapshot? {
        get { store.reading("conversations.people.\(scope)") } nonmutating set { store.keep(newValue, as: "conversations.people.\(scope)") }
    }
    /// The agent's messages with the other agents, as the store keeps them (`AgentMessagesReading`).
    private var agentMessages: [AgentMessage]? { store.reading(AgentMessagesReading.name(scope)) }
    /// The words of this visit's failed read of them, while the store keeps none.
    @State private var agentsFailure: String?
    @State private var agent = ""
    @State private var person = 0
    @State private var ownOpen: Int?
    private var open: Int? {
        get { openBinding?.wrappedValue ?? ownOpen }
        nonmutating set { if let openBinding { openBinding.wrappedValue = newValue } else { ownOpen = newValue } }
    }
    /// When this visit began: a line about a kept reading waits a second for the read that is on its way (`Held`).
    @State private var opened = ContinuousClock.now
    private let client = PeopleClient()
    /// The conversations, read when the agent's chat first opens (`PagePrefetch`).
    static let prefetch = PagePrefetch(agent: { "conversations.list.\($0)" }, feature: People.conversationsFeature) { hub, database, agent in
        PeopleReading.current(try await PeopleClient().conversations(hub: hub, database: database, agent: agent).conversations,
                              at: Date().timeIntervalSince1970)
    }

    init(store: FleetStore, scope: String, grouped: Bool = false, people: Bool = true, open: Binding<Int?>? = nil,
         openAgent: Binding<String?>? = nil) {
        self.store = store
        self.scope = scope
        self.grouped = grouped
        self.people = people
        self.openBinding = open
        self.openAgentBinding = openAgent
        // This page's agent from the first frame, so a kept reading draws for it at once.
        _agent = State(initialValue: scope)
    }

    private var listName: String { "conversations.list.\(scope)" }
    /// **One person's list only once it is read** (review of 3 November 2026): the list of the person chosen before, or
    /// everybody's, stood under a new choice until its read came, and an empty one said "No conversations" over a person
    /// who has some.
    private var reading: PeopleReading<[Conversation]> { person == 0 ? all : narrowed ?? .loading }
    private var now: Double { store.state?.time ?? Date().timeIntervalSince1970 }
    private var offered: Bool { store.state?.ui_features?.contains(People.conversationsFeature) == true && people }
    private var conversations: [Conversation] { reading.value ?? [] }
    /// The agent's conversations with the other agents: in its People, and not while one person is chosen.
    private var agentsOffered: Bool { grouped && store.state?.ui_features?.contains(AgentMessages.feature) == true }
    private var agentConversations: [AgentConversation] {
        agentsOffered && person == 0 ? AgentConversation.of(scope, messages: agentMessages ?? []) : []
    }

    var body: some View {
        Group {
            if let id = open {
                ConversationPage(store: store, id: id, backTitle: String(l10n: "Conversations"), back: { open = nil })
            } else {
                list
            }
        }
        .font(FleetStyle.body).foregroundStyle(FleetStyle.text)
        .task(id: "\(store.hub)/\(store.state?.db ?? "")") {
            narrowed = nil; agent = scope; person = 0
            if openBinding == nil { ownOpen = nil }
            let start = ContinuousClock.now
            while !Task.isCancelled {
                await read(since: start)
                await readAgents()
                do { try await store.nap(5) } catch { return }
            }
        }
    }

    @ViewBuilder private var list: some View {
        if grouped { group } else { page }
    }

    /// The conversations as a group of the agent's People part: the heading with the person filter while there is a
    /// conversation with a person or one is chosen, the rows or the empty card, and the reading's own lines. The rows
    /// come in one frame, once every reading that they need has answered.
    private var group: some View {
        let peopleRead = !offered || reading.value != nil
        let agentsRead = !agentsOffered || person != 0 || agentMessages != nil
        let peopleLoading: Bool = if case .loading = reading { offered } else { false }
        let loading = peopleLoading || agentsOffered && person == 0 && agentMessages == nil && agentsFailure == nil
        let rows = (conversations.map(GroupRow.person) + agentConversations.map(GroupRow.agent))
            .sorted { ($0.last, $0.id) > ($1.last, $1.id) }
        return VStack(alignment: .leading, spacing: FleetSpace.block) {
            FormSection("Conversations") {
                if offered || agentsOffered, peopleRead, agentsRead {
                    ForEach(rows) { row in
                        switch row {
                        case .person(let conversation): self.row(conversation)
                        case .agent(let conversation): agentRow(conversation)
                        }
                    }
                    // The words of the agent's other empty groups, which hold with a person chosen in the filter too.
                    if rows.isEmpty { FormEmpty("No conversations", symbol: "bubble.left.and.bubble.right") }
                }
            } accessory: {
                if offered, !conversations.isEmpty || person != 0 { personSelect }
            }
            if offered || agentsOffered {
                if loading, store.connectionError == nil {
                    LoadingLine(String(l10n: "Reading the conversations…"))
                } else if !peopleRead || !agentsRead {
                    readingRow
                }
            }
            statusLine
        }
    }

    /// One row of the group: a conversation with a person, or with another agent.
    private enum GroupRow: Identifiable {
        case person(Conversation)
        case agent(AgentConversation)

        var id: String {
            switch self {
            case .person(let conversation): "person-\(conversation.id)"
            case .agent(let conversation): "agent-\(conversation.other)"
            }
        }

        var last: Double {
            switch self {
            case .person(let conversation): conversation.last ?? conversation.created ?? 0
            case .agent(let conversation): conversation.last
            }
        }
    }

    private var page: some View {
        FleetPage("Conversations") {
            if offered { filters }
            Group {
                if !offered {
                    FormSection { FormRow("Your hub has no conversations yet", symbol: "bubble.left.and.bubble.right") }
                } else if case .loading = reading, store.connectionError == nil {
                    // The first visit: nothing of the list until it is read, then all of it in one frame. While the
                    // hub does not answer nothing is read, and the failed row stands in its place.
                    LoadingLine(String(l10n: "Reading the conversations…"))
                } else if reading.value == nil {
                    readingRow
                } else {
                    FormSection {
                        ForEach(conversations) { row($0) }
                        if conversations.isEmpty {
                            FormEmpty("No conversations yet", symbol: "bubble.left.and.bubble.right")
                        }
                    }
                }
            }
            statusLine
        }
    }

    /// A line about a kept reading that the read on its way can take away: held for its second (`Held`).
    @ViewBuilder private func held(@ViewBuilder _ line: () -> some View) -> some View {
        if person == 0, store.readingWaits(listName, since: opened) { Held(since: opened) { line() } } else { line() }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            personSelect
            Spacer(minLength: 8)
        }
    }

    /// The person whose conversations show: on the page's own line, or on the group's heading.
    private var personSelect: some View {
        FleetSelect("Person", selection: $person, options:
            [FleetOption(0, "All people", mark: .symbol("person.2"))]
            + (peopleList?.peopleList ?? []).map { FleetOption($0.id, $0.name, detail: $0.roleWord, mark: .symbol("person.crop.circle")) })
            .accessibilityIdentifier("conversations-person")
            .onChange(of: agent) { Task { await read() } }
            .onChange(of: person) { narrowed = nil; Task { await read() } }
    }

    /// The agents that hold a conversation, from the conversations themselves and the people's lists.
    private var agentNames: [String] {
        var names = conversations.map(\.agent)
        names += (peopleList?.peopleList ?? []).flatMap(\.agentNames)
        return Array(Set(names)).sorted()
    }

    /// One conversation: who talked to which agent, the last thing said, and one mark for what waits.
    ///
    /// The whole row is already one button that opens the conversation, so the mark is the shape and the colour
    /// and nothing that can be pressed; the sentence this row used to print as a third line is on the pointer and
    /// off the row itself for a reader. The last thing said is the record, not a state, so it stays.
    private func row(_ conversation: Conversation) -> some View {
        let state = conversation.state(now: now)
        return Button {
            // The conversation's own page has this row's person and its Pause in its first frame.
            if store.reading(ConversationPage.headName(conversation.id)) as Conversation? == nil {
                store.keep(conversation, as: ConversationPage.headName(conversation.id))
            }
            open = conversation.id
        } label: {
            HStack(spacing: 0) {
                // **In an agent's own group the row wears the person's mark** (6 November 2026): every row there is
                // this agent's, so its glyph on each one read as a conversation with the agent itself beside the rows
                // of the other agents, which wear their own. On the page of all agents the agent's glyph tells them apart.
                RowMark {
                    if grouped {
                        Image(systemName: "person.crop.circle").font(IconMetrics.symbol(18)).foregroundStyle(FleetStyle.muted)
                            .frame(width: GlyphSize.row, height: GlyphSize.row)
                    } else {
                        AgentGlyph(name: conversation.agent, size: GlyphSize.row)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(conversation.person?.name ?? String(l10n: "Somebody")).font(FormMetrics.title)
                            .foregroundStyle(FleetStyle.text).lineLimit(1)
                        // In an agent's own group every row is that agent's: the role alone (the owner, 13 November
                        // 2026: "review all other pages for the same issues!!").
                        Text(grouped ? conversation.person?.roleWord ?? ""
                             : "\(conversation.person?.roleWord ?? "") · \(People.agentWord(conversation.agent))")
                            .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                    }
                    if let line = conversation.line {
                        Text(line).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                // The app's mark a word's space before the age, which it touched.
                if let app = conversation.app { BrandMark(app: app, size: 13).foregroundStyle(FleetStyle.muted).padding(.trailing, 6) }
                if let last = conversation.last {
                    Text(activityAge(last, now: now)).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                        .help(fleetDate(last))
                }
                // Last before the chevron: the age is "2 min ago" in one row and "yesterday" in the next, so
                // anything further left would not line up down the list.
                RowStateMark(state: conversation.mark(now: now))
                    .accessibilityIdentifier("conversation-state-\(conversation.id)")
                Image(systemName: "chevron.right").font(IconMetrics.symbol(11, weight: .semibold)).foregroundStyle(FleetStyle.muted)
            }
            .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 11).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(FleetRowButtonStyle())
        .help(state?.words ?? String(l10n: "Nothing waits."))
        .accessibilityLabel(conversation.person?.name ?? String(l10n: "Somebody"))
        .accessibilityValue("\(People.agentWord(conversation.agent)). \(state?.words ?? String(l10n: "Nothing waits."))")
        .accessibilityIdentifier("conversation-\(conversation.id)")
    }

    /// One conversation with another agent: its glyph and its name, the last thing said, and its age, in the columns of
    /// a person's row. Nothing in it waits for him, so the place of a person's mark stays empty.
    private func agentRow(_ conversation: AgentConversation) -> some View {
        Button { openAgentBinding?.wrappedValue = conversation.other } label: {
            HStack(spacing: 0) {
                RowMark { AgentGlyph(name: conversation.other, size: GlyphSize.row) }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // No "Agent" after the name: its glyph says it, where a person's row wears the person's mark.
                        Text(People.agentWord(conversation.other)).font(FormMetrics.title)
                            .foregroundStyle(FleetStyle.text).lineLimit(1)
                    }
                    if let line = conversation.line {
                        Text(line).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                Text(activityAge(conversation.last, now: now)).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                    .help(fleetDate(conversation.last))
                Color.clear.frame(width: IconMetrics.small, height: IconMetrics.small).accessibilityHidden(true)
                Image(systemName: "chevron.right").font(IconMetrics.symbol(11, weight: .semibold)).foregroundStyle(FleetStyle.muted)
            }
            .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 11).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(FleetRowButtonStyle())
        .accessibilityLabel(People.agentWord(conversation.other))
        .accessibilityValue("Agent")
        .accessibilityIdentifier("agent-conversation-\(conversation.other)")
    }

    @ViewBuilder private var readingRow: some View {
        // Not while the window's notice says the outage (`FleetStore.hubNoticeShows`; fix round 3, item 33).
        let failure = reading.failure ?? (agentMessages == nil ? agentsFailure : nil)
        if (failure != nil || store.connectionError != nil) && !store.hubNoticeShows {
            held {
                FormSection {
                    FormRow("The conversations are unavailable", symbol: "exclamationmark.circle", warning: failure)
                        .accessibilityIdentifier("conversations-failed")
                }
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        // Not while the window's notice says the outage (fix round 3c; item 33: an outage is said once).
        if reading.isOld && !store.hubNoticeShows {
            held {
                Text("Last reading \(activityAge(reading.at, now: now).lowercased()). Founderizer reads again every 5 seconds.")
                    .font(FormMetrics.detail).foregroundStyle(.orange).accessibilityIdentifier("conversations-stale")
            }
        }
    }

    /// One reading of the conversations of the person chosen, or of all of them, which the store keeps.
    private func read(since start: ContinuousClock.Instant? = nil) async {
        guard offered, let db = store.state?.db else { return }
        let hub = store.hub, who = agent, which = person
        var first = false
        if case .loading = reading { first = true }
        do {
            let list = try await client.conversations(hub: hub, database: db, agent: who.isEmpty ? nil : who,
                                                      person: which == 0 ? nil : which)
            if first, let start { await store.settle(since: start) }
            guard store.hub == hub, store.state?.db == db, agent == who, person == which else { return }
            if which == 0 { all = .current(list.conversations, at: now) } else { narrowed = .current(list.conversations, at: now) }
        } catch {
            if first, let start { await store.settle(since: start) }
            guard store.hub == hub, store.state?.db == db, agent == who, person == which else { return }
            let failed = reading.aged ?? .failed(People.reason(error))
            if which == 0 { all = failed } else { narrowed = failed }
        }
        // The people are only for the dropdown: a hub without them keeps the page working.
        if store.state?.ui_features?.contains(People.feature) == true,
           let fresh = try? await client.people(hub: hub, database: db), store.state?.db == db {
            peopleList = fresh
        }
    }

    /// One reading of the agent's messages with the other agents: the whole of them the first time, then only what came
    /// since.
    private func readAgents() async {
        guard agentsOffered else { return }
        switch await AgentMessagesReading.read(store, agent: scope) {
        case .read: agentsFailure = nil
        case .failed(let reason): agentsFailure = reason
        case .notAsked: break
        }
    }
}

/// **One agent's messages with the other agents, as the store keeps them** for its Conversations and for its chats
/// with each of the others (`AgentConversationPage`): the whole of them at the first reading, after that only what
/// came since the newest one kept (`GET /ui/agent-messages?after=`), which costs one small request.
enum AgentMessagesReading {
    enum Outcome: Equatable { case notAsked, read, failed(String) }

    /// At most this many pages of 200 in one reading.
    static let pages = 25

    nonisolated static func name(_ agent: String) -> String { "conversations.agents.\(agent)" }

    /// An agent's messages, read when its chat first opens (`PagePrefetch`), so its People draws them at once.
    static let prefetch = PagePrefetch(agent: { name($0) }, feature: AgentMessages.feature) { hub, database, agent in
        AgentMessages.merged([], try await ChatAppsClient().agentMessages(hub: hub, database: database, agent: agent,
                                                                         after: 0, pages: pages))
    }

    /// Reads what came after the newest message the store keeps for `agent`, and keeps it with them.
    @MainActor static func read(_ store: FleetStore, agent: String) async -> Outcome {
        guard store.state?.ui_features?.contains(AgentMessages.feature) == true, store.isFresh,
              let database = store.state?.db else { return .notAsked }
        let hub = store.hub, kept: [AgentMessage]? = store.reading(name(agent))
        do {
            let fresh = try await ChatAppsClient().agentMessages(hub: hub, database: database, agent: agent,
                                                                 after: kept?.last?.id ?? 0, pages: pages)
            // Another reading kept newer ones meanwhile, or the hub changed: this answer is not the newest.
            guard store.hub == hub, store.state?.db == database,
                  (store.reading(name(agent)) as [AgentMessage]?)?.last?.id == kept?.last?.id else { return .read }
            // The first answer is kept even when it is empty: they are read, and the group does not wait for them again.
            if !fresh.isEmpty || kept == nil { store.keep(AgentMessages.merged(kept ?? [], fresh), as: name(agent)) }
            return .read
        } catch {
            return .failed(People.reason(error))
        }
    }
}
