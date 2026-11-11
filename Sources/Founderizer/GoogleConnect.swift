import AppKit
import FleetCore
import SwiftUI

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

/// One Connect of a Google account to the fleet, from the press to what it did. Settings › Apps keeps it: its press
/// stands on the service's heading, and its lines under it (`GoogleConnectStatus`).
///
/// The account is the unit, as it is on the hub: `POST /ui/google/connect` names no agent, and the account the owner
/// connects is the fleet's. Who may use it, and at what level, is the item's own control — one account, as many
/// agents as the owner gives it to. The Connect opens a listener on 127.0.0.1, the consent page of that one service
/// in the browser, and gives the code back to the hub, which keeps the refresh token and never hands it out. It asks
/// for one service's permission only, and Google keeps what the account allowed before.
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

    func start(store: FleetStore, service: GoogleService, connected: @escaping () async -> Void) {
        guard running == nil else { return }
        running = Task { await connect(store: store, service: service, connected: connected) }
    }

    func cancel() { running?.cancel() }

    /// The account joins the fleet, and nothing else happens: who uses it is the next step, on the account itself, and
    /// it is why one account can reach six agents.
    private func connect(store: FleetStore, service: GoogleService, connected: () async -> Void) async {
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
            note = ("\(email) is connected.", false)
            await connected()
        } catch {
            note = Task.isCancelled ? ("Connect stopped.", false) : (reason(error), true)
        }
        busy = nil
        running = nil
    }

    private func reason(_ error: Error) -> String {
        if case HubError.refusal(_, let words) = error { return words }
        if error is URLError { return "The hub did not answer. Look at the accounts before you try again." }
        return error.localizedDescription
    }
}
