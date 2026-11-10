import FleetCore
import SwiftUI

/// Delete… asked from an agent's menu (`AgentMenu`): the agent whose confirmation stands over the window.
struct AgentDeleteRequest: Identifiable, Equatable {
    let agent: String
    var id: String { agent }
}

/// **"Delete Juno?" over the window** (the owner's yes of 7 November 2026 to the mockup): the agent's glyph, the question,
/// one line of what goes on its server and which agents there stay, then Cancel and Delete. Delete sends the command at
/// once; when the hub refuses, its own words stay in the card.
struct AgentDeleteCard: View {
    @Bindable var store: FleetStore
    let agent: String
    let close: () -> Void
    @State private var busy = false
    @State private var refusal: String?

    /// The servers as the app read them last, for the line: who else is on the agent's server.
    private var list: ServerList? { store.reading("servers.list") }

    var body: some View {
        VStack(spacing: 14) {
            AgentGlyph(name: agent, size: GlyphSize.hero, dot: false)
            Text(AgentRemoval.question(agent)).font(FormMetrics.title).accessibilityAddTraits(.isHeader)
            if let line = AgentRemoval.line(agent, in: list) {
                Text(line).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let refusal {
                Text(refusal).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("agent-delete-refusal")
            }
            HStack(spacing: 8) {
                Button("Cancel") { close() }.buttonStyle(FleetOutlineButtonStyle()).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("agent-delete-cancel")
                // The app's one loading look while the command is on its way (T-13), and Delete only while it can act.
                if busy {
                    ShimmeringWords(text: "Deleting").accessibilityElement().accessibilityLabel("Deleting")
                } else if store.canWrite {
                    Button("Delete", role: .destructive) { Task { await delete() } }.buttonStyle(FleetDangerButtonStyle())
                        .accessibilityIdentifier("agent-delete-confirm")
                }
            }.padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .padding(22).frame(width: 360)
        .font(FleetStyle.body).foregroundStyle(FleetStyle.text)
        .task { await readServers() }
    }

    private func delete() async {
        busy = true; refusal = nil
        defer { busy = false }
        if let words = await AgentDeletion.send(store: store, agent: agent) { refusal = words } else { close() }
    }

    /// A fresh reading of the servers, so the line names the agents there now.
    private func readServers() async {
        guard let database = store.state?.db,
              let read = try? await HubClient().servers(hub: store.hub, database: database) else { return }
        store.keep(read, as: "servers.list")
    }
}

/// **Delete…, sent** (hub feature `agent_remove`): the command against the team.json that the app reads now, once more
/// when another write changed it meanwhile. The confirmation's Delete and a stopped removal's Try again send it.
@MainActor enum AgentDeletion {
    /// nil once the hub took it, or the hub's own words when it refused.
    static func send(store: FleetStore, agent: String) async -> String? {
        guard let database = store.state?.db else { return "The hub has not answered. Try again." }
        for attempt in 0..<2 {
            do {
                let team = try await HubClient().team(hub: store.hub, database: database)
                let receipt = try await HubClient().removeAgent(hub: store.hub, database: database, client: store.installation,
                                                                agent: agent, sha256: team.sha256)
                leave(agent, for: receipt.server, store: store)
                await store.refresh()
                return nil
            } catch let HubError.refusal(status, words) {
                if status == 409, attempt == 0, words.contains("team.json changed") { continue }
                return words
            } catch {
                return "The hub has not answered. Try again."
            }
        }
        return "The hub has not answered. Try again."
    }

    /// A page of the agent that is gone gives way: its chat or details to Tasks, its server's page to that server's own,
    /// and its pin goes, so a new agent of that name starts unpinned.
    private static func leave(_ agent: String, for server: String?, store: FleetStore) {
        if store.destination.agentName == agent { store.destination = .activity }
        if case .server(let name) = store.destination, name == agent {
            store.destination = server.map { .server($0) } ?? .settings(.servers)
        }
        if store.pinned.contains(agent) { store.togglePin(agent) }
    }
}
