import FleetCore
import SwiftUI

/// One conversation (UI-API.md 1.17): the whole record, oldest first — what the person wrote, what the agent
/// answered and how it was delivered, what the agent asked the owner, and what the owner answered. The owner only
/// reads here; the four tools of the locked window are the agent's, and this page sends no message.
///
/// Pause keeps every message that arrives and lets no agent answer it; the open window stops at its next tool call.
/// The page reads the new items every 3 seconds while it shows, and a person's text is always plain text.
///
/// **It is a chat** (the owner's yes of 6 November 2026, with the chats between two agents): the person at the left and
/// the agent at the right, each in a bubble (`ReadChat`); under a reply how the chat app delivered it, and under a
/// person's message that the agent has not read it yet. What the agent asked the owner and what he answered stand in
/// the middle, in the look of the chat's time stamps, because the person never sees them.
struct ConversationPage: View {
    @Bindable var store: FleetStore
    let id: Int
    let backTitle: String
    let back: () -> Void

    /// The readings are the store's (`FleetStore.reading`), by the conversation's number wherever it opens: the record
    /// he read last shows in the first frame when he comes back, and the read that starts then adds only what is new.
    private var head: Conversation? {
        get { store.reading(Self.headName(id)) } nonmutating set { store.keep(newValue, as: Self.headName(id)) }
    }
    private var items: [ConversationItem] {
        get { store.reading("conversation.items.\(id)") ?? [] } nonmutating set { store.keep(newValue, as: "conversation.items.\(id)") }
    }
    private var readAt: Date? {
        get { store.reading("conversation.read_at.\(id)") } nonmutating set { store.keep(newValue, as: "conversation.read_at.\(id)") }
    }
    @State private var readError: String?
    @State private var busy = false
    @State private var problem: String?
    private let client = PeopleClient()

    private var now: Double { store.state?.time ?? Date().timeIntervalSince1970 }
    private var canWrite: Bool { store.isFresh && store.state?.db != nil && !busy }
    /// The head of one conversation, which the Conversations list keeps too when a row opens it.
    static func headName(_ id: Int) -> String { "conversation.head.\(id)" }

    var body: some View {
        ReadChatPage(title: head?.person?.name ?? String(l10n: "Conversation"), back: FleetBack(backTitle, action: back)) {
            if let head {
                Button(head.isPaused ? "Let it run" : "Pause") { Task { await pause(!head.isPaused) } }
                    .buttonStyle(FleetOutlineButtonStyle()).disabled(!canWrite)
                    .help(head.isPaused
                          ? "The agent answers again, and reads what came in while it was paused."
                          : "Every message is kept, and no agent answers it.")
                    .accessibilityIdentifier("conversation-pause")
            }
        } chat: {
            if readAt != nil, !items.isEmpty {
                ReadChat(entries: entries, footer: AnyView(status.padding(.top, 12)))
            } else {
                // The first visit, a read that failed, or a conversation with nothing in it yet: a page's blocks under
                // its name.
                VStack(alignment: .leading, spacing: FleetSpace.block) {
                    if readAt == nil, readError == nil, store.connectionError == nil {
                        // The first visit: nothing of the record until it is read, then all of it in one frame. While
                        // the hub does not answer nothing is read, and the failed row stands in its place.
                        LoadingLine(String(l10n: "Reading the conversation…"))
                    } else if readAt == nil {
                        // Not while the window's notice says the outage (`FleetStore.hubNoticeShows`; fix round 3,
                        // item 33).
                        if !store.hubNoticeShows {
                            FormSection {
                                FormRow("The conversation is unavailable", symbol: "exclamationmark.circle", warning: readError)
                                    .accessibilityIdentifier("conversation-failed")
                            }
                        }
                    } else {
                        FormSection { FormEmpty("No messages yet", symbol: "bubble.left") }
                    }
                    status
                }
                .frame(maxWidth: FormMetrics.formWidth, alignment: .leading)
                .padding(.top, FleetSpace.block)
                .fleetColumn()
            }
        }
        .font(FleetStyle.body).foregroundStyle(FleetStyle.text)
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(id)") {
            readError = nil; problem = nil
            let start = ContinuousClock.now
            while !Task.isCancelled {
                await read(since: start)
                do { try await store.nap(3) } catch { return }
            }
        }
    }

    /// The record as a chat: what the person wrote at the left, the agent's replies at the right, and what the agent
    /// asked the owner and his answers in the middle.
    private var entries: [ReadChatEntry] {
        let agent = head?.agent ?? "", person = head?.person?.name
        return items.map { item -> ReadChatEntry in
            switch item.who {
            case "person":
                .message(ReadChatMessage(id: item.id, ours: false, who: .person(item.said(person: person, agent: agent)),
                                         text: item.text, markdown: false, created: item.created,
                                         under: item.read_at == nil
                                            ? AnyView(Text("Not read yet").font(ChatStyle.detail).foregroundStyle(FleetStyle.muted))
                                            : nil))
            case "agent":
                .message(ReadChatMessage(id: item.id, ours: true, who: .agent(agent), text: item.text, markdown: false,
                                         created: item.created,
                                         under: item.delivery.map { AnyView(ConversationDeliveryLine(store: store, delivery: $0, app: head?.app)) }))
            default:
                .note(ReadChatNote(id: item.id, created: item.created, symbol: Self.symbol(item),
                                   who: item.said(person: person, agent: agent), state: item.actionState, text: item.text))
            }
        }
    }

    /// The mark of a line in the middle: his own answer, or what the agent asked him for.
    private static func symbol(_ item: ConversationItem) -> String {
        switch item.who {
        case "owner": "person.crop.circle.fill"
        case "action": item.need?.kind == "work" ? "tray.and.arrow.up" : "questionmark.bubble"
        default: "circle"
        }
    }

    @ViewBuilder private var status: some View {
        if let problem {
            Text(problem).font(FormMetrics.detail).foregroundStyle(.orange).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("conversation-problem")
        } else if let readError, readAt != nil, !store.hubNoticeShows {
            // Not while the window's notice says the outage (`FleetStore.hubNoticeShows`).
            Text("Last reading \(readAt!.formatted(date: .omitted, time: .shortened)). \(readError) Founderizer reads again.")
                .font(FormMetrics.detail).foregroundStyle(.orange).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("conversation-stale")
        }
    }

    // MARK: the hub

    /// The pages after the newest item this page has: at most 25 pages of 200 in one reading. The head comes with the
    /// items, so a first reading draws its title and its record in one frame.
    private func read(since start: ContinuousClock.Instant? = nil) async {
        guard let db = store.state?.db else { return }
        let hub = store.hub, first = readAt == nil
        var fresh = items, record: Conversation?, pages = 0
        do {
            while !Task.isCancelled, pages < 25 {
                let page = try await client.conversation(hub: hub, database: db, id: id,
                                                         after: fresh.compactMap(\.number).max() ?? 0)
                guard store.hub == hub, store.state?.db == db else { return }
                record = page.head
                fresh += page.items.filter { item in !fresh.contains { $0.id == item.id } }
                pages += 1
                if page.items.count < 200 { break }
            }
            if first, let start { await store.settle(since: start) }
            guard store.hub == hub, store.state?.db == db else { return }
            if let record { head = record }
            items = fresh; readAt = Date(); readError = nil
        } catch {
            if first, let start { await store.settle(since: start) }
            guard store.hub == hub, store.state?.db == db else { return }
            if let record { head = record }
            readError = People.reason(error)
        }
    }

    private func pause(_ pause: Bool) async {
        guard canWrite, let db = store.state?.db else { return }
        busy = true; problem = nil
        defer { busy = false }
        do {
            let receipt = try await client.conversation(hub: store.hub, database: db, client: store.installation,
                                                        id: id, pause: pause)
            if let conversation = receipt.conversation { head = conversation }
        } catch { problem = People.reason(error) }
        await read()
    }
}

/// **One agent's conversation with another agent, as a chat** (the owner, 6 November 2026: "it needs to look like a
/// chat", and his yes to its mockup the same day): every message between the two, the agent of the page at the right and
/// the other at the left, newest at the bottom (`ReadChat`). Under the other agent's page the sides change. He reads it:
/// the two agents write it, so it has no composer and no Pause. It reads what came since every 3 seconds while it shows,
/// into the reading that the agent's Conversations keep (`AgentMessagesReading`).
struct AgentConversationPage: View {
    @Bindable var store: FleetStore
    let agent: String
    let other: String
    let back: () -> Void
    @State private var failure: String?

    private var kept: [AgentMessage]? { store.reading(AgentMessagesReading.name(agent)) }
    private var messages: [AgentMessage] {
        AgentConversation.of(agent, messages: kept ?? []).first { $0.other == other }?.messages ?? []
    }

    var body: some View {
        ReadChatPage(title: People.agentWord(other), back: FleetBack("People", action: back)) {
            EmptyView()
        } chat: {
            if !messages.isEmpty {
                ReadChat(entries: messages.map { message in
                    .message(ReadChatMessage(id: message.label, ours: message.sender == agent, who: .agent(message.sender),
                                             text: message.text, markdown: true, created: message.created))
                })
            } else {
                VStack(alignment: .leading, spacing: FleetSpace.block) {
                    if kept == nil, failure == nil, store.connectionError == nil {
                        LoadingLine(String(l10n: "Reading the conversation…"))
                    } else if kept == nil {
                        if !store.hubNoticeShows {
                            FormSection {
                                FormRow("The conversation is unavailable", symbol: "exclamationmark.circle", warning: failure)
                                    .accessibilityIdentifier("conversation-failed")
                            }
                        }
                    } else {
                        FormSection { FormEmpty("No messages yet", symbol: "bubble.left") }
                    }
                }
                .frame(maxWidth: FormMetrics.formWidth, alignment: .leading)
                .padding(.top, FleetSpace.block)
                .fleetColumn()
            }
        }
        .font(FleetStyle.body).foregroundStyle(FleetStyle.text)
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(agent)") {
            while !Task.isCancelled {
                switch await AgentMessagesReading.read(store, agent: agent) {
                case .read: failure = nil
                case .failed(let reason): failure = reason
                case .notAsked: break
                }
                do { try await store.nap(3) } catch { return }
            }
        }
    }
}
