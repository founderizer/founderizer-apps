import FleetCore
import SwiftUI

// The small views that People, a person, Conversations and one conversation share: the four states of a reading, the
// role dropdown, the agents a person may reach, and the delivery mark under a reply.

/// The four states of a page that reads the hub again and again (UI-PATTERNS, "Statuses must be true"): loading, a
/// current reading, an old one, and a failed read. An old reading is never shown as current.
enum PeopleReading<Value> {
    case loading
    case current(Value, at: Double)
    case stale(Value, at: Double)
    case failed(String)

    var value: Value? {
        switch self {
        case .current(let value, _), .stale(let value, _): value
        case .loading, .failed: nil
        }
    }

    var at: Double {
        switch self {
        case .current(_, let at), .stale(_, let at): at
        case .loading, .failed: 0
        }
    }

    var isOld: Bool { if case .stale = self { true } else { false } }
    var failure: String? { if case .failed(let why) = self { why } else { nil } }

    /// The same reading, marked old; nil when there is none to keep.
    var aged: PeopleReading<Value>? {
        switch self {
        case .current(let value, let at), .stale(let value, let at): .stale(value, at: at)
        case .loading, .failed: nil
        }
    }
}

/// A reading that the store reads before its page opens (`PagePrefetch`) crosses from the read to the store.
extension PeopleReading: Sendable where Value: Sendable {}

/// The role of a person: a dropdown, and under it the one line the agent is told. The words are the hub's own
/// (`GET /ui/people` `roles`), so the app writes none of them.
struct RoleRow: View {
    let roles: [PeopleSnapshot.Role]
    @Binding var role: String
    var saving: SaveState?
    var disabled = false
    var retry: () -> Void = {}

    var body: some View {
        // **The role's line of eight words at most, and what the agent is told on hover** (D-2, as Add person's role
        // cards; fix round 2): the row showed the agent's whole instruction at rest. **No symbol** (the owner, 30
        // October 2026, of a person's card: "Remove the 3 icons"; margins row 14): every title of the card begins 16
        // points in, with Name and the note's.
        FormRow("Role", detail: Self.line(role)) {
            HStack(spacing: 8) {
                if let saving { SaveMark(state: saving, retry: retry) }
                FleetSelect("Role", selection: $role, options: options)
                    .disabled(disabled).accessibilityIdentifier("person-role")
            }
        }.help(means ?? "")
    }

    /// The hub's roles, in its order. A person keeps a role that the list no longer has, so that row shows it too.
    private var options: [FleetOption<String>] {
        let names = roles.map(\.role) + (role.isEmpty || roles.contains { $0.role == role } ? [] : [role])
        return names.map { FleetOption($0, People.roleWord($0), mark: .symbol(Self.symbol($0))) }
    }

    /// What the agent is told about such a person, from the hub.
    private var means: String? {
        roles.first { $0.role == role }.map { String(l10n: "The agent is told: \($0.means)") }
    }

    static func symbol(_ role: String) -> String {
        switch role {
        case "customer": "cart"
        case "employee": "person.2"
        case "supervisor": "eye"
        case "deputy": "checkmark.seal"
        default: "person"
        }
    }

    /// **A role in his terms, in eight words at most** (D-2, the owner's yes of 28 October 2026): what such a person gets,
    /// under the role's name on Add person's cards. What the agent is told is the card's hover. A role of his own has
    /// no line of ours: its name says it.
    static func line(_ role: String) -> String? {
        switch role {
        case "customer": String(l10n: "Answers only what you allow")
        case "employee": String(l10n: "Answers about the work, takes requests")
        case "supervisor": String(l10n: "Watches the state and progress of work")
        case "deputy": String(l10n: "Decides for you in this conversation")
        default: nil
        }
    }
}

/// The agents a person may write to: one row for each, with a checkbox. An empty list is nobody, never everybody —
/// so the card says what it is by its own heading and the state line of the person's row says "No agent yet".
///
/// Every row says the same thing in the same place (the owner, 19 October 2026: one row carried "Cannot chat" and
/// the next carried nothing, so the list read as broken). An agent that cannot hold a conversation says **why**,
/// once, on its own line under its name, where every other row's line is; it never carries a second label beside
/// the checkbox, and an agent that can hold one says nothing at all.
struct PersonAgentsCard: View {
    let agents: [FleetAgent]
    /// The hub's own word about an agent of this person's list that cannot hold a conversation now.
    let says: [String: String]
    @Binding var chosen: [String]
    var saving: SaveState?
    var disabled = false
    /// The card's heading, or nil where the page's own title already says it.
    var heading: String? = String(l10n: "Can talk to")
    var retry: () -> Void = {}
    /// **All access, or only these, on each ticked row where the hub gives one** (feature `person_scope`; the owner's
    /// yes of 11 November 2026 to its mockup): what the person may use of that agent, by the agent's name. A row
    /// without one has no select.
    var access: [String: PersonScope] = [:]
    /// The save of each row's select, by the agent's name.
    var accessSaving: [String: SaveState] = [:]
    /// All access (true) or Only these… (false), chosen on an agent's row.
    var chooseAccess: (String, Bool) -> Void = { _, _ in }
    var retryAccess: (String) -> Void = { _ in }

    var body: some View {
        let shared = sharedReason
        VStack(alignment: .leading, spacing: FleetSpace.inside) {
            FormSection(heading) {
                ForEach(agents) { agent in row(agent, shared: shared?.reason) }
                if agents.isEmpty {
                    FormEmpty("No agent of this fleet can hold a conversation.", symbol: "person.slash")
                }
            } accessory: {
                if let saving { SaveMark(state: saving, retry: retry) }
            }
            // **A reason that several agents share is said once, under the list** (D-2): the same sentence stood under
            // Vps, Mini and Nova. It names them, so it says whom it is about.
            if let shared {
                Text("\(People.agentWords(shared.agents)): \(Self.afterColon(shared.reason))").font(FormMetrics.detail).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.horizontal, 2)
                    .accessibilityIdentifier("person-agents-shared-reason")
            }
        }
    }

    /// The hub decides who can chat; its own line wins wherever it gave one.
    private func why(_ agent: FleetAgent) -> String? {
        says[agent.name] ?? People.cannotChat(role: agent.role, runtime: agent.runtime, active: agent.active)
    }

    /// The reason, after the colon that follows the names, starts in lower case where its first word is an ordinary one.
    static func afterColon(_ reason: String) -> String {
        let ordinary = ["A", "An", "The", "This", "That", "Its", "Their", "No", "Each", "Every"]
        guard let first = reason.split(separator: " ", maxSplits: 1).first, ordinary.contains(String(first)) else { return reason }
        return reason.prefix(1).lowercased() + reason.dropFirst()
    }

    /// The one reason that two agents or more of the list share, with them, or nil.
    private var sharedReason: (reason: String, agents: [String])? {
        var byReason: [String: [String]] = [:], order: [String] = []
        for agent in agents {
            guard let reason = why(agent) else { continue }
            if byReason[reason] == nil { order.append(reason) }
            byReason[reason, default: []].append(agent.name)
        }
        guard let reason = order.max(by: { (byReason[$0]?.count ?? 0) < (byReason[$1]?.count ?? 0) }),
              let names = byReason[reason], names.count > 1 else { return nil }
        return (reason, names)
    }

    private func row(_ agent: FleetAgent, shared: String?) -> some View {
        let picked = chosen.contains(agent.name)
        let why = why(agent)
        // **The agent's glyph, with its dot, before its name** (the owner, 30 October 2026: "Yes, in all agent lists"), as
        // the sidebar and the item cards draw an agent: the names begin 50 points in.
        return FormRow(People.agentWord(agent.name), mark: AgentGlyph(name: agent.name, size: GlyphSize.inline),
                       warning: why == shared ? nil : why) {
            HStack(spacing: 8) {
                if picked, let scope = access[agent.name] { accessSelect(agent.name, scope: scope) }
                Toggle("", isOn: Binding(get: { picked }, set: { on in
                    var names = chosen.filter { $0 != agent.name }
                    if on { names.append(agent.name) }
                    chosen = names.sorted()
                })).labelsHidden().toggleStyle(FleetCheckboxStyle()).disabled(disabled)
                    .accessibilityIdentifier("person-agent-\(agent.name)")
            }
        }
    }

    /// **The select before the checkbox**: All access, or Only these…, which shows the list in a few words while one
    /// is set ("abc-crm"). All access writes at once; Only these… opens the page of the list. It stands also while the
    /// agent cannot chat, so that he can always set All again.
    @ViewBuilder private func accessSelect(_ agent: String, scope: PersonScope) -> some View {
        SaveMark(state: accessSaving[agent], retry: { retryAccess(agent) })
        FleetSelect("Access with \(People.agentWord(agent))",
                    options: [FleetOption(true, "All access"), FleetOption(false, "Only these…")],
                    selection: scope.isAll) { all in chooseAccess(agent, all) } label: {
            FleetSelectLabel(title: scope.isAll ? String(l10n: "All access") : scope.short ?? String(l10n: "Only these…"))
        }
        .disabled(disabled)
        .accessibilityIdentifier("person-access-\(agent)")
    }
}

/// Under an agent's reply: how the chat app delivered it, as the icons of a chat, with the words on hover. Not sent
/// or not confirmed is orange with Send again — only the owner decides to send a part again.
struct ConversationDeliveryLine: View {
    @Bindable var store: FleetStore
    let delivery: ConversationItem.Delivery
    let app: String?
    @State private var sending = false
    @State private var failure: String?
    @State private var sentAgain: Int?
    private let client = ChatAppsClient()

    var body: some View {
        let words = delivery.words(app: app, time: messageTime)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    if let app { BrandMark(app: app, size: 11).foregroundStyle(FleetStyle.muted) }
                    DeliveryMark(state: delivery.state)
                }
                .help(words)
                .accessibilityElement(children: .ignore).accessibilityLabel(words)
                if delivery.canSendAgain, sentAgain != delivery.outbound {
                    MessageAction(symbol: "arrow.clockwise", label: String(l10n: "Send again"),
                                  help: String(l10n: "Send again. The first one can still arrive."), height: 16) {
                        Task { await sendAgain() }
                    }.foregroundStyle(FleetStyle.muted).disabled(sending || !store.isFresh)
                }
                if sending { ProgressView().controlSize(.mini) }
            }
            if let failure {
                Text(failure).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }.font(FormMetrics.detail).padding(.top, 2)
    }

    private func sendAgain() async {
        guard let outbound = delivery.outbound, let db = store.state?.db else { return }
        sending = true; failure = nil
        defer { sending = false }
        do {
            _ = try await client.sendAgain(hub: store.hub, database: db, client: store.installation, outbound: outbound)
            sentAgain = outbound
        } catch { failure = People.reason(error) }
    }
}

/// A delivery state as an icon: a clock while it waits, one check when sent, two when delivered or read (its words on
/// hover say which), and an orange exclamation mark when it failed or is not confirmed.
private struct DeliveryMark: View {
    let state: String

    var body: some View {
        Group {
            switch state {
            case "sent": Image(systemName: "checkmark").foregroundStyle(FleetStyle.muted)
            case "delivered": checks.foregroundStyle(FleetStyle.muted)
            // Read is a state, and a state is never violet (D-8): its word is on hover.
            case "read": checks.foregroundStyle(FleetStyle.muted)
            case "failed", "unknown", "expired": Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            default: Image(systemName: "clock").foregroundStyle(FleetStyle.muted)
            }
        }.font(IconMetrics.symbol(10, weight: .semibold))
    }

    private var checks: some View {
        HStack(spacing: -5) { Image(systemName: "checkmark"); Image(systemName: "checkmark") }
    }
}
