import AppKit
import FleetCore
import SwiftUI

/// Connecting a Google account to the fleet. The account is the unit, as it is on the hub: `POST /ui/google/connect`
/// names no agent, and the account the owner connects is the fleet's. Who may use it, and at what level, is the
/// item's own control — one account, as many agents as the owner gives it to.
///
/// The Connect opens a listener on 127.0.0.1, the consent page of that one service in the browser, and gives the
/// code back to the hub, which keeps the refresh token and never hands it out. It asks for one service's permission
/// only, and Google keeps what the account allowed before.
struct GoogleConnectRow: View {
    let store: FleetStore
    let service: GoogleService
    /// One agent's own page: the account that comes in is given to it at Read, because that is plainly what the
    /// owner meant there — the same rule `MCPAddSection` follows for a server added from an agent. nil is the
    /// fleet's own page, where an account joins and no agent gets it.
    var giveTo: String?
    /// Read the accounts again when one is connected.
    let connected: () async -> Void
    @State private var model = GoogleConnecting()

    var body: some View {
        FormRow("Connect an account", symbol: "person.badge.plus", detail: model.busy,
                warning: model.note?.warning == true ? model.note?.text : nil) {
            HStack(spacing: 8) {
                if model.running != nil {
                    Button("Cancel") { model.cancel() }.buttonStyle(FleetOutlineButtonStyle())
                        .accessibilityIdentifier("google-connect-cancel")
                } else {
                    Button("Connect") { model.start(store: store, service: service, giveTo: giveTo, connected: connected) }
                        .buttonStyle(FleetOutlineButtonStyle()).disabled(!model.canConnect(store))
                        .accessibilityIdentifier("google-connect-\(service.rawValue)")
                }
            }
        }
        if let note = model.note, !note.warning {
            FormRow(note.text, symbol: "checkmark.circle")
        }
    }
}

/// What a Connect of Settings › Apps is doing, under its service's heading, whose button started it: the step that
/// goes on with its Cancel, or what the last one did. The page draws it only while there is something to say.
struct GoogleConnectStatus: View {
    let model: GoogleConnecting

    var body: some View {
        FormSection {
            if let busy = model.busy {
                FormRow(busy) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        if model.running != nil {
                            Button("Cancel") { model.cancel() }.buttonStyle(FleetOutlineButtonStyle())
                                .accessibilityIdentifier("google-connect-cancel")
                        }
                    }
                }
            } else if let note = model.note {
                FormRow(note.text, symbol: note.warning ? "exclamationmark.triangle" : "checkmark.circle")
            }
        }
    }
}

/// One Connect of a Google account, from the press to what it did. Whatever draws the press keeps it: the row of an
/// agent's `+`, or Settings › Apps, whose press stands on the service's heading and whose lines stand under it.
@MainActor @Observable
final class GoogleConnecting {
    /// The Connect that can still stop: until the browser has answered.
    private(set) var running: Task<Void, Never>?
    private(set) var busy: String?
    private(set) var note: (text: String, warning: Bool)?
    @ObservationIgnored private let client = GoogleClient()

    /// A step that goes on, or what the last one did.
    var shows: Bool { busy != nil || note != nil }

    func canConnect(_ store: FleetStore) -> Bool {
        store.state?.ui_features?.contains(Google.feature) == true && store.isFresh && busy == nil
    }

    func start(store: FleetStore, service: GoogleService, giveTo: String?, connected: @escaping () async -> Void) {
        guard running == nil else { return }
        running = Task { await connect(store: store, service: service, giveTo: giveTo, connected: connected) }
    }

    func cancel() { running?.cancel() }

    /// The account joins the fleet. On the fleet's own page nothing else happens — that is the next step, on the
    /// account itself, and it is why one account can reach six agents. On one agent's page the account is then
    /// given to that agent at Read, so "add a Drive account for this agent" is one step and not three.
    private func connect(store: FleetStore, service: GoogleService, giveTo: String?,
                         connected: () async -> Void) async {
        guard let database = store.state?.db else { running = nil; return }
        let hub = store.hub, installation = store.installation
        busy = "Starting…"
        note = nil
        do {
            let loopback = try await GoogleLoopback.open()
            defer { loopback.stop() }
            let start = try await client.connect(hub: hub, database: database, client: installation,
                                                 redirectURI: loopback.redirectURI, service: service, account: nil)
            busy = "Waiting for the sign-in in your browser…"
            NSWorkspace.shared.open(start.url)
            let code = try await loopback.code(state: start.state)
            running = nil
            busy = "Saving…"
            let email = try await client.finish(hub: hub, database: database, client: installation,
                                                state: start.state, code: code).email
            if let giveTo {
                busy = "Giving it to \(giveTo.agentLabel)…"
                try await handOver(email, to: giveTo, service: service, store: store, hub: hub, database: database)
                note = ("\(email) is connected, and \(giveTo.agentLabel) can read it.", false)
            } else {
                note = ("\(email) is connected.", false)
            }
            await connected()
        } catch {
            note = Task.isCancelled ? ("Connect stopped.", false) : (reason(error), true)
        }
        busy = nil
        running = nil
    }

    /// Gives the account that just joined to one agent, at Read, with the write the account's detail uses. The team
    /// file moved when the account came in, so its new digest is read here and not held from before.
    private func handOver(_ email: String, to agent: String, service: GoogleService, store: FleetStore, hub: URL,
                          database: String) async throws {
        let reading = try await ResourcesClient().read(hub: hub, database: database)
        let account = reading.resources.first { $0.kind == service.rawValue && $0.what == email }
        let access = account?.googleAccess(giving: agent, level: GoogleLevel.read.rawValue)
            ?? [agent: GoogleLevel.read]
        try await client.saveAccess(hub: hub, database: database, client: store.installation,
                                    sha256: reading.sha256, account: email, service: service, access: access)
    }

    private func reason(_ error: Error) -> String {
        if case HubError.refusal(_, let words) = error { return words }
        if error is URLError { return "The hub did not answer. Look at the accounts before you try again." }
        return error.localizedDescription
    }
}
