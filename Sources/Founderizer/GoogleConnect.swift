import AppKit
import FleetCore
import SwiftUI

/// What a Connect of Settings › Apps is doing, under its service's heading, whose button started it: the notice before
/// Google's page with its Cancel and Continue, the step that goes on with its Cancel, or what the last one did. The page
/// draws it only while there is something to say.
struct GoogleConnectStatus: View {
    let model: GoogleConnecting
    let service: GoogleService
    /// The notice's Continue may start the Connect now (`GoogleConnecting.canContinue`).
    let canContinue: Bool
    /// The notice's Continue: the Connect itself.
    let proceed: () -> Void

    var body: some View {
        FormSection {
            if model.asking {
                notice
            } else if let busy = model.busy {
                FormRow(busy, detail: model.hint) {
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

    /// **The notice before Google's page** (the owner's "Yes, both as drawn" of 16 November 2026): its words, then
    /// Cancel and the white Continue at the right, as a form's buttons stand in its card.
    private var notice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(service.notice).font(FormMetrics.text).foregroundStyle(FleetStyle.text)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .accessibilityIdentifier("google-notice-\(service.rawValue)")
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { model.dismiss() }.buttonStyle(FleetOutlineButtonStyle())
                    .accessibilityIdentifier("google-notice-cancel")
                Button("Continue", action: proceed).buttonStyle(FleetPrimaryButtonStyle()).disabled(!canContinue)
                    .accessibilityIdentifier("google-notice-continue")
            }
        }
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 12)
    }
}

/// **Disconnect, at the end of a Google account's card** (`AccessSettings`; the owner's "Yes, both as drawn" of 16
/// November 2026): a red Disconnect; its press puts one line in its place, what Google does (`Google.disconnectWords`),
/// with Cancel and Disconnect, as Remove device and Remove person ask in their row. No dialog. While it goes on, a
/// spinner stands in its place; a refusal is one orange line under it, in the hub's words.
struct GoogleDisconnectRow: View {
    enum Step { case button, asking, working }
    let step: Step
    /// What the hub said when the last Disconnect of this account did not go through.
    let refused: String?
    /// The card can write now.
    let enabled: Bool
    let press: () -> Void
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            switch step {
            case .working:
                ProgressView().controlSize(.small).frame(minHeight: FormMetrics.control)
            case .asking:
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(IconMetrics.symbol(13)).foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(Google.disconnectWords).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Cancel", action: cancel).buttonStyle(FleetOutlineButtonStyle())
                        .accessibilityIdentifier("google-disconnect-cancel")
                    Button("Disconnect", action: confirm).buttonStyle(FleetDangerButtonStyle()).disabled(!enabled)
                        .accessibilityIdentifier("google-disconnect-confirm")
                }
            case .button:
                Button("Disconnect", action: press).buttonStyle(FleetDangerButtonStyle()).disabled(!enabled)
                    .accessibilityIdentifier("google-disconnect")
            }
            // The last refusal stands under the button only: the press puts its one line in its place.
            if step == .button, let refused {
                Text(refused).font(FormMetrics.detail).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("google-disconnect-refused")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// **A Disconnect of one Google account that did not end well** (the reviews of 16 November 2026), kept by the store for
/// the hub and generation that it ran on, under the account (`name`): the Gmail and the Google Drive card of the account
/// both show its line and Disconnect again while something of the account is left, also after its card closed
/// meanwhile, or when its card's own service left the list before a later write was refused. A card of a connected
/// account forgets it when it opens again, and so does a Connect of the account that ends well.
struct GoogleDisconnectLeft {
    /// The hub's words of the refusal that stopped it; the app's own when the hub gave none (it did not answer, or the
    /// clean-up ended with something left and no refusal of a newer version on its way).
    var refused: String

    /// Its name in the store, with the hub and generation in it: the store keeps one slot for each name, so a Connect of
    /// the same account on another hub does not take this hub's line away.
    static func name(_ account: String, hub: URL, database: String) -> String {
        "google.disconnect.\(hub.absoluteString)\n\(database)\n\(account.lowercased())"
    }
}

/// One Connect of a Google account to the fleet, from the press to what it did. Settings › Apps keeps it: its press
/// stands on the service's heading, and its lines under it (`GoogleConnectStatus`).
///
/// The account is the unit, as it is on the hub: `POST /ui/google/connect` names no agent, and the account the owner
/// connects is the fleet's. Who may use it, and at what level, is the item's own control — one account, as many
/// agents as the owner gives it to. **The press shows the notice first** (`GoogleConnectNotice`, Google's policy), and
/// only its Continue starts the Connect: a listener on 127.0.0.1, Google's consent page in the browser, and the code
/// back to the hub, which keeps the refresh token and never hands it out. It asks for one service's permission (in a
/// fleet with accounts of an own client, for theirs too), and Google keeps what the account allowed before.
@MainActor @Observable
final class GoogleConnecting {
    /// The Connect that can still stop: until the browser has answered.
    private(set) var running: Task<Void, Never>?
    private(set) var busy: String?
    /// The detail of the wait for the browser while Google has not verified Founderizer's app
    /// (`GoogleConnectStart.hint`): how to pass Google's warning page. Only during that wait.
    private(set) var hint: String?
    private(set) var note: (text: String, warning: Bool)?
    /// The notice before Google's page, from the press of Connect account to its Continue or Cancel.
    private var notice = GoogleConnectNotice()
    @ObservationIgnored private let client = GoogleClient()

    /// The notice shows.
    var asking: Bool { notice.shows }
    /// The notice, a step that goes on, or what the last one did.
    var shows: Bool { asking || busy != nil || note != nil }

    /// Connect account can be pressed: not while its notice shows, as Add MCP server waits while its form is open.
    func canConnect(_ store: FleetStore) -> Bool { canContinue(store) && !asking }

    /// The notice's Continue can start the Connect.
    func canContinue(_ store: FleetStore) -> Bool {
        store.state?.ui_features?.contains(Google.feature) == true && store.writesNow && busy == nil
    }

    /// Connect account: the notice, and nothing else yet.
    func ask() {
        notice.press(connecting: busy != nil || running != nil)
        if asking { note = nil }
    }

    /// The notice's Cancel, or another hub: no Connect.
    func dismiss() { notice.dismiss() }

    /// The notice's Continue: the Connect itself. The first line of the wait stands at once, so the card never goes
    /// between the notice and the wait.
    func start(store: FleetStore, service: GoogleService, connected: @escaping () async -> Void) {
        guard running == nil, let consent = notice.proceed() else { return }
        busy = String(l10n: "Starting…")
        note = nil
        running = Task { await connect(store: store, service: service, consent: consent, connected: connected) }
    }

    func cancel() { running?.cancel() }

    /// The account joins the fleet, and nothing else happens: who uses it is the next step, on the account itself, and
    /// it is why one account can reach six agents.
    private func connect(store: FleetStore, service: GoogleService, consent: GoogleConsent,
                         connected: () async -> Void) async {
        guard let database = store.state?.db else { busy = nil; running = nil; return }
        let hub = store.hub, installation = store.installation
        do {
            let loopback = try await GoogleLoopback.open()
            defer { loopback.stop() }
            let start = try await client.connect(hub: hub, database: database, client: installation,
                                                 redirectURI: loopback.redirectURI, service: service, account: nil,
                                                 consent: consent)
            busy = String(l10n: "Waiting for the sign-in in your browser…")
            hint = start.hint
            NSWorkspace.shared.open(start.url)
            let code = try await loopback.code(state: start.state)
            running = nil
            hint = nil
            busy = String(l10n: "Saving…")
            let email = try await client.finish(hub: hub, database: database, client: installation,
                                                state: start.state, code: code).email
            note = (String(l10n: "\(email) is connected."), false)
            // A Disconnect of this account that did not end well says nothing more once the account is back.
            if store.hub == hub, store.state?.db == database {
                store.keep(nil, as: GoogleDisconnectLeft.name(email, hub: hub, database: database))
            }
            await connected()
        } catch {
            note = Task.isCancelled ? (String(l10n: "Connect stopped."), false) : (reason(error), true)
        }
        busy = nil
        hint = nil
        running = nil
    }

    private func reason(_ error: Error) -> String {
        if case HubError.refusal(let refused) = error { return refused.words }
        if error is URLError { return String(l10n: "The hub did not answer. Look at the accounts before you try again.") }
        return error.localizedDescription
    }
}
