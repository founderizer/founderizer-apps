import AppKit
import FleetCore
import SwiftUI

private let mcpClient = MCPClient()

/// Adding an MCP server (owner feature `mcp`). The server is the unit: it is added once and belongs to the fleet,
/// and the list below hands it to the agents that should have it. Added from an agent's own page, it also gives it
/// to that agent, because that is plainly what the owner meant there.
///
/// No console anywhere: a remote server is an address, a program is its command line, and a key is **named**, never
/// pasted — the hub's rule is that the owner holds every credential, so `key` is the variable of an API key the
/// agent already reads from the Secrets page. The form can also read a server's own published configuration, and
/// drops any value that snippet carries.
///
/// Settings › Apps opens the form from the heading of its MCP servers, where every group of a page has its add (the
/// owner's map of 28 October 2026 put the MCP servers in Apps): the page keeps the form's state then (`shared`), and
/// the section draws only what there is to show. In an agent's `+` the section keeps its own, with the row that
/// opens the form.
struct MCPAddSection: View {
    let store: FleetStore
    /// One agent's page: the new server is given to it as well. nil is the fleet's own page.
    var agent: String?
    /// The page's own, when its header opens the form. nil keeps one here, with its own row and its own reading.
    var shared: MCPAdding?
    @State private var own = MCPAdding()

    private var model: MCPAdding { shared ?? own }

    var body: some View {
        if model.offered(store) {
            FormSection {
                if model.adding {
                    MCPForm(draft: Bindable(model).draft, busy: !model.canChange(store), paste: { model.paste() },
                            add: { Task { await model.add(store: store, agent: agent) } }, cancel: { model.close() })
                } else if shared == nil {
                    FormRow("Add an MCP server", symbol: "plus.circle") {
                        Button("Add") { model.open() }
                            .buttonStyle(FleetOutlineButtonStyle()).disabled(!model.canOpen(store))
                            .accessibilityIdentifier("mcp-add")
                    }
                }
                if let busy = model.busy {
                    FormRow(busy) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            if let connecting = model.connecting {
                                Button("Cancel") { connecting.cancel() }.buttonStyle(FleetOutlineButtonStyle())
                            }
                        }
                    }
                } else if let message = model.message {
                    FormRow(message.text, symbol: message.warning ? "exclamationmark.triangle" : "checkmark.circle")
                }
            }
            .task(id: "\(store.hub)/\(store.state?.db ?? "")") {
                // A shared model is read by the page that keeps it, which is always there.
                if shared == nil { await model.start(store: store) }
            }
        }
    }
}

/// The state of adding one MCP server: its draft, the step that goes on, and what the last one did. Whatever decides
/// whether the form is on the page keeps it, because a section that is not there cannot read what decides that.
@MainActor @Observable
final class MCPAdding {
    private(set) var snapshot: IntegrationsSnapshot?
    private(set) var adding = false
    var draft = MCPDraft()
    private(set) var busy: String?
    private(set) var message: (text: String, warning: Bool)?
    /// The sign-in that waits for the browser, for its Cancel.
    private(set) var connecting: Task<Void, Never>?
    @ObservationIgnored private let client = IntegrationsClient()

    /// The form, a step that goes on, or what the last one did.
    var shows: Bool { adding || busy != nil || message != nil }

    func offered(_ store: FleetStore) -> Bool { store.state?.ui_features?.contains(MCP.feature) == true }

    /// The form opens before the team is read (the loading contract, C4.2): only its own Add waits for that reading,
    /// which is the version a new server is written against (`canChange`).
    func canOpen(_ store: FleetStore) -> Bool { offered(store) && store.isFresh && busy == nil }

    func canChange(_ store: FleetStore) -> Bool { canOpen(store) && snapshot != nil }

    func open() { adding = true; draft = MCPDraft(); message = nil }

    func close() { adding = false; draft = MCPDraft() }

    /// Another hub or another generation: the old one's form goes, and the servers are read again.
    func start(store: FleetStore) async {
        adding = false; draft = MCPDraft(); message = nil
        await read(store: store)
    }

    /// The owner copies a server's published configuration and the form fills itself. Nothing is sent: the snippet
    /// is read on this Mac, and a key in it is dropped.
    func paste() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            message = (String(l10n: "There is nothing to paste."), true)
            return
        }
        guard let read = MCP.read(snippet: text) else {
            message = (String(l10n: "That is not a server's configuration."), true)
            return
        }
        draft = read
        message = nil
    }

    /// Add: the server, then its sign-in, then — on an agent's page — that agent's switch. Each step says what it
    /// did, so a step that fails leaves a server the owner can connect again from its row.
    func add(store: FleetStore, agent: String?) async {
        guard canChange(store), let server = draft.server, let name = draft.name, let db = store.state?.db else { return }
        let free = snapshot.map { snapshot in
            var free = name, number = 2
            while !snapshot.free(name: free) {
                free = String(name.prefix(28)) + "-\(number)"
                number += 1
            }
            return free
        } ?? name
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines), auth = draft.auth
        adding = false
        draft = MCPDraft()
        await run(String(l10n: "Adding \(title)…"), store: store) { current, _ in
            try await mcpClient.save(hub: store.hub, database: db, client: store.installation, sha256: current.sha256,
                                     name: free, server: server)
            return String(l10n: "\(title) is in Founderizer as \(free).")
        }
        guard message?.warning != true else { return }
        await read(store: store)
        if auth == .oauth, let tool = snapshot?.servers.first(where: { $0.name == free })?.tool {
            // The sign-in runs as a task of its own, so that its Cancel can stop the wait for the browser.
            let signIn = Task { await connect(free, tool, store: store) }
            connecting = signIn
            await signIn.value
            guard message?.warning != true else { return }
        }
        if let agent { await give(free, to: agent, store: store) }
    }

    private func give(_ name: String, to agent: String, store: FleetStore) async {
        let hub = store.hub, installation = store.installation, label = agent.agentLabel, client = client
        await run(String(l10n: "Giving \(label) the server \(name)…"), store: store) { current, db in
            let agents = Integrations.agents(current.agents(of: name), agent: agent, on: true,
                                             order: current.lines.map(\.agent))
            _ = try await client.saveTool(hub: hub, database: db, client: installation, sha256: current.sha256,
                                          tool: name, agents: agents)
            return String(l10n: "\(label) gets \(name) in its next task session.")
        }
    }

    /// One Connect: the hub finds the server's OAuth endpoints and registers Founderizer as a client, the owner
    /// signs in in his browser, and the loopback listener catches the code. No token reaches the app.
    private func connect(_ name: String, _ tool: IntegrationsSnapshot.Tool, store: FleetStore) async {
        guard let db = store.state?.db else { return }
        let hub = store.hub, installation = store.installation
        busy = String(l10n: "Starting the sign-in to \(tool.title)…")
        message = nil
        do {
            let loopback = try await GoogleLoopback.open()
            defer { loopback.stop() }
            let start = try await mcpClient.connect(hub: hub, database: db, client: installation, name: name,
                                                    redirectURI: loopback.redirectURI)
            busy = String(l10n: "Waiting for the sign-in in your browser…")
            NSWorkspace.shared.open(start.url)
            let code = try await loopback.code(state: start.state)
            connecting = nil
            busy = String(l10n: "Saving the connection…")
            let done = try await mcpClient.finish(hub: hub, database: db, client: installation, state: start.state,
                                                  code: code)
            message = (done.tools.isEmpty ? String(l10n: "\(tool.title) is connected.")
                       : String(l10n: "\(tool.title) is connected · \(done.tools.count) tools."), false)
        } catch {
            message = Task.isCancelled ? (String(l10n: "The sign-in stopped."), false) : (Self.reason(error), true)
        }
        busy = nil
        connecting = nil
        if !Task.isCancelled { await read(store: store) }
    }

    /// One change against the team.json version this section read. When the team changed meanwhile (409), it reads
    /// again and makes the same change once more.
    private func run(_ words: String, store: FleetStore,
                     _ work: (IntegrationsSnapshot, String) async throws -> String) async {
        guard var current = snapshot, let db = store.state?.db else { return }
        let hub = store.hub
        busy = words
        message = nil
        do {
            for attempt in 1...2 {
                do {
                    message = (try await work(current, db), false)
                    break
                } catch HubError.refusal(409, _) where attempt == 1 {
                    current = try await client.read(hub: hub, database: db)
                }
            }
        } catch { message = (Self.reason(error), true) }
        busy = nil
        await read(store: store)
    }

    private func read(store: FleetStore) async {
        guard offered(store), let db = store.state?.db else { return }
        let hub = store.hub
        let fresh = try? await client.read(hub: hub, database: db)
        if store.hub == hub, store.state?.db == db, let fresh { snapshot = fresh }
    }

    private static func reason(_ error: Error) -> String {
        if case HubError.refusal(_, let text) = error { return text }
        if error is URLError { return String(l10n: "The hub did not answer. Look at the list before you try again.") }
        return error.localizedDescription
    }
}

/// The form: what it is called, where it is, and how it signs in. Add stays off until the form is one the hub
/// takes, so a mistake needs no round trip.
private struct MCPForm: View {
    @Binding var draft: MCPDraft
    let busy: Bool
    let paste: () -> Void
    let add: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                FleetSegmented("Kind", selection: $draft.kind, options: MCPKind.allCases.map { FleetOption($0, $0.title) })
                    .accessibilityIdentifier("mcp-kind")
                Spacer(minLength: 0)
                Button("Paste its configuration", action: paste).buttonStyle(FleetOutlineButtonStyle())
                    .accessibilityIdentifier("mcp-paste")
            }
            field(String(l10n: "Name"), "Acme CRM", text: $draft.title, identifier: "mcp-title")
            if draft.kind == .remote {
                field(String(l10n: "Address"), "https://mcp.example.com/", text: $draft.address, identifier: "mcp-address")
            } else {
                field(String(l10n: "Program"), "notes-mcp stdio", text: $draft.command, identifier: "mcp-command")
            }
            Picker("", selection: $draft.auth) {
                ForEach(draft.choices, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.radioGroup).labelsHidden().accessibilityIdentifier("mcp-auth")
            if draft.auth == .key {
                field(String(l10n: "API key"), "ACME_CRM_KEY", text: $draft.key, identifier: "mcp-key")
                if draft.kind == .local {
                    field(String(l10n: "The program reads it as"), draft.key.isEmpty ? "NOTES_TOKEN" : draft.key,
                          text: $draft.variable, identifier: "mcp-variable")
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(FleetOutlineButtonStyle())
                Button(draft.auth == .oauth ? "Add and sign in" : "Add", action: add)
                    .buttonStyle(FleetPrimaryButtonStyle()).disabled(!draft.isComplete || busy)
                    .accessibilityIdentifier("mcp-save")
            }
        }.padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 12)
    }

    private func field(_ label: String, _ hint: String, text: Binding<String>, identifier: String) -> some View {
        HStack(spacing: 10) {
            Text(label).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                .frame(width: 150, alignment: .leading)
            TextField(text: text, prompt: Text(verbatim: "")) { Text(hint) }
                .fieldPlaceholder(hint, shows: text.wrappedValue.isEmpty).fleetField()
                .accessibilityIdentifier(identifier).onSubmit { if draft.isComplete && !busy { add() } }
        }
    }
}
