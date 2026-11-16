import AppKit
import FleetCore
import SwiftUI

private let mcpClient = MCPClient()

/// Adding an MCP server (owner feature `mcp`). The server is the unit: it is added once and belongs to the fleet,
/// and the list below hands it to the agents that should have it. Added from an agent's own page, it also gives it
/// to that agent, with Reads it on each of its keys (`MCPKeyGrants`), because that is plainly what the owner meant
/// there.
///
/// No console anywhere: a remote server is an address, a program is its line, and a key is never written in
/// `team.json`. Every key that the owner types goes from its secure field into the central vault as an API key of the
/// Secrets page, named after the server (`MCP.sessionVariable`), and the server names only that variable: a program's
/// in its `env`, a remote server's as its `key`. The form can find a server in the official MCP Registry
/// (`mcp_find`), or read a server's own published configuration, and drops any key that snippet carries.
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
                    MCPForm(model: model, store: store, busy: !model.canChange(store),
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
                } else if let said = model.said {
                    FormRow(said.text, symbol: said.warning ? "exclamationmark.triangle" : "checkmark.circle")
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
    /// Find a server: the words in its field, and the servers that the hub found for them.
    var words = ""
    private(set) var found: [MCPFound]?
    /// A search is on its way.
    private(set) var finding = false
    /// The hub's version of each package that the Program line named, by `MCPPackageRef.key`.
    private(set) var versions: [String: MCPPackageVersion] = [:]
    /// The words of the search that is on its way or shown: Return and the pause after typing ask once.
    @ObservationIgnored private var asked: String?
    /// The words that a search and a lookup put into the message line, so that their next answer takes away only those.
    @ObservationIgnored private var findSaid: String?
    @ObservationIgnored private var lookupSaid: String?
    /// **Each key of the form that Add registered with the vault**, by its row: its reference, its variable and whether
    /// the vault has its value. Add again after a step that failed puts no second key in, and a key whose step failed
    /// goes again under the same reference. No value is kept here.
    @ObservationIgnored private var keyed: [UUID: (reference: String, variable: String, done: Bool)] = [:]
    /// The name that the hub keeps the server of this form's Add under, and the name that its title gave then: Add again
    /// saves the same server, whose keys are named after it, and never a second one.
    @ObservationIgnored private var savingAs: (from: String, name: String)?
    /// What the last Connect ended with, when it failed.
    @ObservationIgnored private var refused: Error?
    @ObservationIgnored private let client = IntegrationsClient()

    /// The form, a step that goes on, or what the last one did.
    var shows: Bool { adding || busy != nil || message != nil }

    /// **The form's one message line**: what the last step did, or else why the form does not take its Program line
    /// (an image, a program that installs or runs code itself, a key in the line).
    var said: (text: String, warning: Bool)? {
        if let message { return message }
        guard adding, let refusal = draft.refusal else { return nil }
        return (refusal.words, true)
    }

    func offered(_ store: FleetStore) -> Bool { store.state?.ui_features?.contains(MCP.feature) == true }

    /// The form opens before the team is read (the loading contract, C4.2): only its own Add waits for that reading,
    /// which is the version a new server is written against (`canChange`).
    func canOpen(_ store: FleetStore) -> Bool { offered(store) && store.isFresh && busy == nil }

    func canChange(_ store: FleetStore) -> Bool { canOpen(store) && snapshot != nil }

    /// The hub's version of the package that the Program line names, once its lookup answered.
    var resolved: MCPPackageVersion? { draft.package.flatMap { versions[$0.key] } }

    func open() { reset(); adding = true; message = nil }

    func close() { reset(); adding = false }

    /// A form with nothing in it: no key of the last one stays in memory.
    private func reset() {
        draft = MCPDraft(); words = ""; found = nil; finding = false; asked = nil; versions = [:]; keyed = [:]
        savingAs = nil
    }

    /// Another hub or another generation: the old one's form goes, and the servers are read again.
    func start(store: FleetStore) async {
        close(); message = nil
        await read(store: store)
    }

    /// The servers again, for the marks of their rows (`MCPSignInAgain`), while the page shows.
    func refresh(store: FleetStore) async { await read(store: store) }

    /// The owner copies a server's published configuration and the form fills itself. Nothing is sent: the snippet
    /// is read on this Mac, and a key in it is dropped. A Docker image, or a program that installs or runs code itself,
    /// says why it is no server for Founderizer.
    func paste() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            message = (String(l10n: "There is nothing to paste."), true)
            return
        }
        guard let read = MCP.read(snippet: text) else {
            message = (MCP.refusal(snippet: text)?.words ?? String(l10n: "That is not a server's configuration."), true)
            return
        }
        draft = read
        keyed = [:]; savingAs = nil; found = nil; asked = nil
        message = nil
    }

    /// Add on a row of Find a server: the form takes that server, and the list goes.
    func pick(_ server: MCPFound) {
        draft = MCPDraft(found: server)
        keyed = [:]; savingAs = nil; found = nil; asked = nil
        message = nil
    }

    /// One field of a program's row. A key that the vault has already gets a new one when its value changes.
    func set(_ field: WritableKeyPath<MCPVariable, String>, to text: String, of id: UUID) {
        guard let index = draft.variables.firstIndex(where: { $0.id == id }) else { return }
        if field == \MCPVariable.value, draft.variables[index].value != text, keyed[id]?.done == true { keyed[id] = nil }
        draft.variables[index][keyPath: field] = text
    }

    /// A remote server's key, in its secure field. A key that the vault has already gets a new one when it changes.
    func setRemoteKey(_ text: String) {
        if draft.remoteKey != text, keyed[draft.remoteKeyID]?.done == true { keyed[draft.remoteKeyID] = nil }
        draft.remoteKey = text
    }

    /// **Find a server**: the hub asks the official MCP Registry for these words (`mcp_find`). Return and the pause
    /// after typing call it; the same words ask once. A refusal is the form's message line, in the hub's words.
    func find(store: FleetStore) async {
        guard adding else { return }
        guard let given = MCP.findWords(words) else {
            found = nil; asked = nil; finding = false
            take(&findSaid)
            return
        }
        guard given != asked, store.state?.ui_features?.contains(MCP.findFeature) == true, let db = store.state?.db else { return }
        asked = given
        finding = true
        do {
            let servers = try await mcpClient.find(hub: store.hub, database: db, client: store.installation, words: given)
            guard asked == given, adding else { return }
            found = servers; finding = false
            take(&findSaid)
        } catch {
            guard asked == given else { return }
            asked = nil; finding = false
            guard !Self.cancelled(error), adding else { return }
            found = nil
            let said = Self.readReason(error)
            message = (said, true); findSaid = said
        }
    }

    /// **The version of the package that the Program line names** (`POST /ui/mcp/package`, `mcp_packages`): the newest
    /// that is at least 7 days old, or the one that the line names when it is. Add waits for it, and writes exactly
    /// that. A refusal (a version newer than 7 days, no such package) is the form's message line, in the hub's words.
    func lookUp(store: FleetStore) async {
        guard adding, let package = draft.package else {
            take(&lookupSaid)
            return
        }
        guard versions[package.key] == nil, store.state?.ui_features?.contains(MCP.packagesFeature) == true,
              let db = store.state?.db else { return }
        do {
            let answer = try await mcpClient.package(hub: store.hub, database: db, client: store.installation, of: package)
            guard adding, !Task.isCancelled else { return }
            versions[package.key] = answer
            take(&lookupSaid)
        } catch {
            guard !Self.cancelled(error), !Task.isCancelled, adding else { return }
            let said = Self.readReason(error)
            message = (said, true); lookupSaid = said
        }
    }

    /// Takes away the line that one lookup put into the message line, and only that line.
    private func take(_ said: inout String?) {
        if let words = said, message?.text == words { message = nil }
        said = nil
    }

    /// **Add: each key into the central vault, then the server, while the form stays.** A server never names a key that
    /// is not there, and **the form closes only once the hub took the server**: a step that failed, or that got no
    /// answer, keeps the form with its rows and the keys that it registered (`keyed`), and Add again saves the same
    /// server under the same name (`savingAs`) with the same keys, and no second one. Then its sign-in and, on an
    /// agent's page, that agent's server and keys. A remote server of Find a server whose Connect finds no OAuth is
    /// saved again with no sign-in, and the message line says so.
    func add(store: FleetStore, agent: String?) async {
        let features = store.state?.ui_features ?? []
        let typed = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canChange(store), var server = draft.server(features: features, resolved: resolved), let name = draft.name,
              store.state?.db != nil else { return }
        let free: String
        if let savingAs, savingAs.from == name {
            free = savingAs.name
        } else {
            free = snapshot.map { snapshot in
                var free = name, number = 2
                while !snapshot.free(name: free) {
                    free = String(name.prefix(28)) + "-\(number)"
                    number += 1
                }
                return free
            } ?? name
            savingAs = (name, free)
        }
        let signsIn = draft.kind == .remote && draft.auth == .oauth, picked = draft.picked
        let keys = draft.keyValues
        if !keys.isEmpty {
            busy = String(l10n: "Saving…")
            message = nil
            do {
                let variables = try await vault(keys, server: free, store: store)
                if draft.kind == .remote { server.key = variables[MCP.remoteKey] } else { server.env = variables }
            } catch {
                busy = nil
                message = (Self.reason(error), true)
                return
            }
            busy = nil
        }
        let saved = server
        await run(String(l10n: "Adding \(typed)…"), store: store) { current, db in
            try await mcpClient.save(hub: store.hub, database: db, client: store.installation, sha256: current.sha256,
                                     name: free, server: saved)
            return String(l10n: "\(typed) is in Founderizer as \(free).")
        }
        guard message?.warning != true else { return }
        close()
        if signsIn, let tool = snapshot?.servers.first(where: { $0.name == free })?.tool {
            // The sign-in runs as a task of its own, so that its Cancel can stop the wait for the browser.
            let signIn = Task { await connect(free, title: tool.title, store: store) }
            connecting = signIn
            await signIn.value
            if picked, let refused, MCP.hasNoOAuth(refused) {
                // A server of the MCP Registry that has no OAuth at all: the same server, with no sign-in.
                let open = MCPServerSpec(title: saved.title, url: saved.url, auth: .none)
                await run(String(l10n: "Adding \(typed)…"), store: store) { current, db in
                    try await mcpClient.save(hub: store.hub, database: db, client: store.installation,
                                             sha256: current.sha256, name: free, server: open)
                    return String(l10n: "\(typed) needs no sign-in. Founderizer added it with no sign-in.")
                }
            }
            guard message?.warning != true else { return }
        }
        if let agent { await give(free, to: agent, store: store) }
    }

    /// **Sign in again** on the row of a server whose access ended (`MCPSignInAgain`): the Connect that Add makes, with
    /// its busy line, its Cancel and its message line over the list.
    func signInAgain(_ name: String, title: String, store: FleetStore) async {
        guard canOpen(store) else { return }
        let signIn = Task { await connect(name, title: title, store: store) }
        connecting = signIn
        await signIn.value
    }

    /// Each key into the central vault as an API key of the Secrets page, and the variable of each: the server's name,
    /// then the program's own variable, or `<SERVER>_KEY` for a remote server's key (`MCP.sessionVariable`), so no
    /// key of the fleet is ever replaced here and no key is named as a variable that a session holds already.
    private func vault(_ keys: [MCPKeyValue], server: String, store: FleetStore) async throws -> [String: String] {
        guard let database = store.state?.db else { throw MCPStop(String(l10n: "No current status of this hub. Nothing was sent.")) }
        let team = try await HubClient().team(hub: store.hub, database: database)
        // The keys that this form registered before are its own, and no other key of that name.
        let ours = Set(keyed.values.map(\.reference))
        var taken = Set((team.logins ?? [:]).compactMap { reference, entry in
            entry.isAPIKey && !ours.contains(reference) ? entry.name : nil
        })
        var variables: [String: String] = [:]
        for key in keys {
            let made = keyed[key.id]
            if let made, made.done {
                variables[key.name] = made.variable
                taken.insert(made.variable)
                continue
            }
            guard let variable = made?.variable ?? MCP.sessionVariable(for: key.name, server: server, taken: taken) else {
                throw MCPStop(String(l10n: "The hub did not take this change. Try again."))
            }
            taken.insert(variable)
            let reference = made?.reference ?? DoorKeyReference.make()
            keyed[key.id] = (reference, variable, false)
            try await Self.put(key.value, variable: variable, reference: reference, store: store)
            keyed[key.id] = (reference, variable, true)
            variables[key.name] = variable
        }
        return variables
    }

    /// One value into the central vault as an API key, as the door's keys go in (`DoorKeys.put`) but held by no agent
    /// yet: sealed here to the vault's key that this Mac pinned, registered with the hub under `reference`, and sent.
    /// The value is in memory for this call only, and no line of the app writes it anywhere.
    private static func put(_ value: String, variable: String, reference: String, store: FleetStore) async throws {
        guard let database = store.state?.db else { throw MCPStop(String(l10n: "No current status of this hub. Nothing was sent.")) }
        let hub = store.hub, client = store.installation
        guard let reading = try await VaultClient().reading(hub: hub, database: database), let fleet = reading.fleetID,
              let recipient = reading.trusted(pin: CentralVaultPins.recipient(hub: hub, fleet: fleet)) else {
            throw MCPStop(String(l10n: "The central vault does not answer with the key this Mac pinned. Nothing was sent."))
        }
        var secret = LoginSecret()
        secret.kind = .apiKey
        secret.env = variable
        secret.password = value
        if let problem = secret.problem { throw MCPStop(problem) }
        let item = try secret.value()
        let sealed = try AgeSeal.seal(item, to: recipient)
        let salts = try await HubClient().secretSalts(hub: hub, database: database, login: reference)
        // The central vault takes a value only with its fingerprint: without one, the hub step makes a catalog entry
        // that can never hold the value.
        let prints = try SecretFingerprint.of(item, salts: salts)
        guard SecretFingerprint.areValid(prints) else {
            throw MCPStop(String(l10n: "The central vault takes a value only with a fingerprint, and this one has none: it has fewer than 8 characters or holds white space. Nothing was sent."))
        }
        _ = try await SecretsClient().add(hub: hub, database: database, client: client, login: reference, title: secret.title,
                                          kind: .apiKey, variable: secret.variable, fingerprints: prints)
        _ = try await VaultClient().intake(hub: hub, database: database, client: client, login: reference, ciphertext: sealed)
    }

    /// On an agent's page: the server for that agent, then Reads it on each of the server's keys (`MCPKeyGrants`), as
    /// the server's card gives it.
    private func give(_ name: String, to agent: String, store: FleetStore) async {
        let hub = store.hub, installation = store.installation, label = agent.agentLabel, client = client
        await run(String(l10n: "Giving \(label) the server \(name)…"), store: store) { current, db in
            let agents = Integrations.agents(current.agents(of: name), agent: agent, on: true,
                                             order: current.lines.map(\.agent))
            _ = try await client.saveTool(hub: hub, database: db, client: installation, sha256: current.sha256,
                                          tool: name, agents: agents)
            try await MCPKeyGrants.follow(name, agent: agent, giving: true, store: store, hub: hub, database: db)
            return String(l10n: "\(label) gets \(name) in its next task session.")
        }
    }

    /// One Connect: the hub finds the server's OAuth endpoints and registers Founderizer as a client, the owner
    /// signs in in his browser, and the loopback listener catches the code. No token reaches the app.
    private func connect(_ name: String, title: String, store: FleetStore) async {
        guard let db = store.state?.db else { return }
        let hub = store.hub, installation = store.installation
        busy = String(l10n: "Starting the sign-in to \(title)…")
        message = nil
        refused = nil
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
            message = (done.tools.isEmpty ? String(l10n: "\(title) is connected.")
                       : String(l10n: "\(title) is connected · \(done.tools.count) tools."), false)
        } catch {
            refused = Task.isCancelled ? nil : error
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
                } catch let error as HubError where error.conflict && attempt == 1 {
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
        if case HubError.refusal(let refused) = error { return refused.words }
        if error is URLError { return String(l10n: "The hub did not answer. Look at the list before you try again.") }
        return error.localizedDescription
    }

    /// Why a search or a lookup has no answer: the hub's words, or that it did not answer. Neither wrote anything.
    private static func readReason(_ error: Error) -> String {
        if case HubError.refusal(let refused) = error { return refused.words }
        if error is URLError { return String(l10n: "The hub did not answer.") }
        return error.localizedDescription
    }

    /// A search or a lookup that newer words or a closed form stopped: it says nothing.
    private static func cancelled(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

/// **The grants that go with one give of an MCP server** (`MCPServerKeys`): after the hub took the server for the agent,
/// the app reads the team again and signs and writes each key's "Reads it", or its end, as a key's own page does:
/// signed for the central vault before the hub's grant, and the end after it (`GrantSigning`).
@MainActor
enum MCPKeyGrants {
    static func follow(_ server: String, agent: String, giving: Bool, store: FleetStore, hub: URL,
                       database: String) async throws {
        let client = store.installation
        let integrations = try await IntegrationsClient().read(hub: hub, database: database)
        let logins = try await HubClient().team(hub: hub, database: database).logins ?? [:]
        let tools = integrations.lines.first { $0.agent == agent }?.tools ?? []
        for (login, grant) in MCPServerKeys.grants(server: server, agent: agent, giving: giving,
                                                   tools: integrations.tools ?? [:], agentTools: tools, logins: logins) {
            if grant != nil {
                try await GrantSigning.grant(grant, login: login, agent: agent, store: store, hub: hub, database: database)
            }
            _ = try await SecretsClient().grant(hub: hub, database: database, client: client, login: login, agent: agent,
                                                grant: grant)
            if grant == nil {
                try await GrantSigning.grant(nil, login: login, agent: agent, store: store, hub: hub, database: database)
            }
        }
    }
}

/// A stop of Add, in the owner's words, in the form's message line.
private struct MCPStop: LocalizedError {
    let errorDescription: String?
    init(_ says: String) { errorDescription = says }
}

/// The form: where the server comes from (Find a server, its pasted configuration, or typed), what it is called, where
/// it is, and how it signs in or which settings and keys its program takes. Add stays off until the form is one the
/// hub takes, so a mistake needs no round trip.
private struct MCPForm: View {
    @Bindable var model: MCPAdding
    let store: FleetStore
    let busy: Bool
    let add: () -> Void
    let cancel: () -> Void

    /// The words of the left column: a field's name, and a program's variable.
    private static let label: CGFloat = 180
    /// The search's example word, which is a server's name in every language.
    private static let example = "notion"
    /// The tallest the results stand before they scroll inside the form.
    private static let results: CGFloat = 264
    /// The pause after typing before a search or a lookup goes.
    private static let pause: Duration = .milliseconds(600)

    private var features: [String] { store.state?.ui_features ?? [] }
    private var finds: Bool { features.contains(MCP.findFeature) }
    private var packages: Bool { features.contains(MCP.packagesFeature) }
    private var complete: Bool { model.draft.isComplete(features: features, resolved: model.resolved) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if finds { search } else { kind; Spacer(minLength: 0) }
                Button("Paste its configuration") { model.paste() }.buttonStyle(FleetOutlineButtonStyle())
                    .accessibilityIdentifier("mcp-paste")
            }
            if finds {
                results
                HStack { kind; Spacer(minLength: 0) }
            }
            field(String(l10n: "Name"), "Acme CRM", text: $model.draft.title, identifier: "mcp-title")
            if model.draft.kind == .remote {
                field(String(l10n: "Address"), "https://mcp.example.com/", text: $model.draft.address, identifier: "mcp-address")
                Picker("", selection: $model.draft.auth) {
                    ForEach(model.draft.choices, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.radioGroup).labelsHidden().accessibilityIdentifier("mcp-auth")
                if model.draft.auth == .key {
                    // The same row as a program's key: its value goes into the vault as <SERVER>_KEY.
                    HStack(spacing: 10) {
                        label(String(l10n: "API key"))
                        keyField(Binding(get: { model.draft.remoteKey }, set: { model.setRemoteKey($0) }),
                                 words: String(l10n: "API key"), identifier: "mcp-key")
                    }
                }
            } else {
                program
                ForEach(model.draft.variables) { variable($0) }
                if packages {
                    Button { model.draft.addSetting() } label: {
                        Label("Add a setting", systemImage: "plus").padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.vertical, -IconMetrics.reach).font(FormMetrics.text)
                    .foregroundStyle(FleetStyle.link).disabled(busy)
                    .accessibilityIdentifier("mcp-add-setting")
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(FleetOutlineButtonStyle())
                Button(model.draft.kind == .remote && model.draft.auth == .oauth ? "Add and sign in" : "Add", action: add)
                    .buttonStyle(FleetPrimaryButtonStyle()).disabled(!complete || busy)
                    .accessibilityIdentifier("mcp-save")
            }
        }
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 12)
        // A short pause after typing: a search, and the version of the package that the Program line names.
        .task(id: model.words) {
            do { try await Task.sleep(for: Self.pause) } catch { return }
            await model.find(store: store)
        }
        .task(id: model.draft.package?.key ?? "") {
            do { try await Task.sleep(for: Self.pause) } catch { return }
            await model.lookUp(store: store)
        }
    }

    private var kind: some View {
        FleetSegmented("Kind", selection: $model.draft.kind, options: MCPKind.allCases.map { FleetOption($0, $0.title) })
            .accessibilityIdentifier("mcp-kind")
    }

    /// **Find a server**, over the official MCP Registry: Return, or a short pause after typing, asks the hub.
    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(IconMetrics.symbol(14)).foregroundStyle(FleetStyle.muted)
                .accessibilityHidden(true)
            TextField(text: $model.words, prompt: Text(verbatim: "")) { Text("Find a server") }
                .fieldPlaceholder(Self.example, shows: model.words.isEmpty).fleetField()
                .onSubmit { Task { await model.find(store: store) } }
                .accessibilityIdentifier("mcp-find")
        }
    }

    /// The servers that the hub found, under the field: each with its mark, its title, who publishes it and where it
    /// comes from, and Add, which fills the form below.
    @ViewBuilder private var results: some View {
        if let found = model.found {
            if found.isEmpty {
                Text("No server matches the search.").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) { ForEach(found) { result($0) } }
                }.frame(maxHeight: Self.results)
            }
        } else if model.finding {
            LoadingLine(String(l10n: "Searching…"))
        }
    }

    private func result(_ server: MCPFound) -> some View {
        HStack(spacing: 0) {
            RowMark {
                Image(systemName: server.isProgram ? "terminal" : "globe").font(IconMetrics.symbol(15))
                    .foregroundStyle(FleetStyle.text)
            }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.title).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(1)
                Text(server.line).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
            }
            .help(server.description ?? "")
            Spacer(minLength: 12)
            Button { model.pick(server) } label: {
                Text("Add").padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.vertical, -IconMetrics.reach).font(FormMetrics.title)
            .foregroundStyle(FleetStyle.link).disabled(busy)
            .accessibilityIdentifier("mcp-found-\(server.id)")
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    /// The Program line, and beside it the version that the hub gave its package: "0.9.0 · PyPI".
    private var program: some View {
        HStack(spacing: 10) {
            label(String(l10n: "Program"))
            TextField(text: $model.draft.command, prompt: Text(verbatim: "")) { Text("Program") }
                .fieldPlaceholder("uvx mcp-server-acme", shows: model.draft.command.isEmpty)
                .fleetField(wrong: !model.draft.command.isEmpty && model.draft.line == nil)
                .accessibilityIdentifier("mcp-command")
                // Return adds a complete form, and asks the hub again for a version that it did not give.
                .onSubmit { if complete && !busy { add() } else { Task { await model.lookUp(store: store) } } }
            if let resolved = model.resolved {
                Text(resolved.words).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1).fixedSize()
                    .textSelection(.enabled).accessibilityIdentifier("mcp-version")
            }
        }
    }

    /// One setting or key of the program: its name at the left (a field of its own in a row that he added), and its
    /// value: a secure field with a lock for a key, which goes into the vault, and a plain field for a setting. A row
    /// whose name the one rule of a secret calls a key's is a key row (`MCPVariable.isKey`).
    @ViewBuilder private func variable(_ row: MCPVariable) -> some View {
        HStack(spacing: 10) {
            if row.named {
                Text(row.name).font(FormMetrics.code).foregroundStyle(FleetStyle.muted).lineLimit(1).truncationMode(.middle)
                    .frame(width: Self.label, alignment: .leading).help(row.about.isEmpty ? row.name : row.about)
            } else {
                TextField(text: binding(\.name, of: row.id), prompt: Text(verbatim: "")) { Text("Name") }
                    .fieldPlaceholder("ACME_REGION", shows: row.name.isEmpty).font(FormMetrics.code)
                    .fleetField(wrong: !row.name.isEmpty && MCP.settingName(row.name) == nil)
                    .frame(width: Self.label)
            }
            if row.isKey {
                keyField(binding(\.value, of: row.id), words: row.name, identifier: "mcp-key-\(row.name)")
            } else {
                let value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
                TextField(text: binding(\.value, of: row.id), prompt: Text(verbatim: "")) { Text(verbatim: row.name) }
                    .fleetField(wrong: !value.isEmpty && !MCP.plainValue(value))
                    .onSubmit { if complete && !busy { add() } }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// **A key's field**, of a program's key row and of a remote server's key: a secure field with a lock, whose value
    /// goes into the central vault and never into `team.json`; an orange edge while it holds a key that the vault
    /// refuses.
    private func keyField(_ value: Binding<String>, words: String, identifier: String) -> some View {
        let key = value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return SecureField(text: value, prompt: Text(verbatim: "")) { Text(verbatim: words) }
            .padding(.trailing, 18)
            .fleetField(wrong: !key.isEmpty && !MCP.isKeyValue(key))
            .overlay(alignment: .trailing) {
                Image(systemName: "lock.fill").font(IconMetrics.symbol(11)).foregroundStyle(FleetStyle.muted)
                    .padding(.trailing, 10).allowsHitTesting(false).accessibilityHidden(true)
            }
            .onSubmit { if complete && !busy { add() } }
            .accessibilityIdentifier(identifier)
    }

    /// One field of a row, through the model, which forgets a key's vault step when its value changes.
    private func binding(_ field: WritableKeyPath<MCPVariable, String>, of id: UUID) -> Binding<String> {
        Binding(get: { model.draft.variables.first { $0.id == id }?[keyPath: field] ?? "" },
                set: { model.set(field, to: $0, of: id) })
    }

    private func label(_ words: String) -> some View {
        Text(words).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).frame(width: Self.label, alignment: .leading)
    }

    private func field(_ label: String, _ hint: String, text: Binding<String>, identifier: String) -> some View {
        HStack(spacing: 10) {
            self.label(label)
            TextField(text: text, prompt: Text(verbatim: "")) { Text(hint) }
                .fieldPlaceholder(hint, shows: text.wrappedValue.isEmpty).fleetField()
                .accessibilityIdentifier(identifier).onSubmit { if complete && !busy { add() } }
        }
    }
}

/// **The mark and Sign in again on the row of a server whose access ended** (the owner's "Yes, all three" and "Row and
/// Needs you", 15 November 2026): the warning mark with its reason behind it, and the Connect of the form
/// (`MCPAdding.signInAgain`), whose busy and message lines stand over the list. Settings › Apps › MCP servers gives it
/// to its rows (`AccessSettings.accessory`).
struct MCPSignInAgain: View {
    let store: FleetStore
    let model: MCPAdding
    /// The server's name at the hub, and its title for the busy line.
    let name: String
    let title: String
    let reason: MCPSignIn

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(IconMetrics.symbol(13)).foregroundStyle(.orange)
                .help(words).accessibilityLabel(words)
            Button("Sign in again") { Task { await model.signInAgain(name, title: title, store: store) } }
                .buttonStyle(FleetOutlineButtonStyle()).disabled(!model.canOpen(store))
                .accessibilityIdentifier("mcp-sign-in-again-\(name)")
        }
    }

    /// The reason behind the mark: the hub's own words of an access that ended (else that it has no connection), that
    /// it has no connection, or when its access ends.
    private var words: String {
        switch reason {
        case .ended(let said): said ?? String(l10n: "Not connected")
        case .notConnected: String(l10n: "Not connected")
        case .ends(let at): String(l10n: "Valid until \(fleetComingTime(at, now: store.state?.time ?? at)).")
        }
    }
}
