import FleetCore
import Observation
import SwiftUI

/// **Turning the connected apps on and off** (the build specification of the MCP address, section 7; the owner's yes of
/// 13 November 2026 to the pictures 2a to 2f: "Yes, build 2a to 2f").
///
/// While the hub names `connect_offer` and says that the feature can be turned on here (a Linux hub of this release,
/// with the feature off), Settings › Servers has the group "Connect an app" under "Your devices": its empty card, and
/// Turn on on its heading. Turn on opens one setup page, his Tailscale key (`ConnectAppKeyStep`). The pasted token goes
/// to `prepareNetwork`, and nowhere else. Then the page goes back to Settings › Servers, and the heading says "Turning
/// on…" while the app runs the rest by itself (`ConnectGate.turnOn`): the root step on the hub's machine, the hub's
/// setting, and the wait until the hub serves `connected_apps`. A step that stopped is the card's failure row: his
/// sentence for it, and Try again only where a retry can work, else Report a problem. Turn off is on the heading of the
/// approved "Connect an app" while the feature is on, behind one confirmation in its card (`ConnectedAppsGroups`).
///
/// **The run's state lives here, in the store, one for each hub** (`FleetStore.connectSwitch`), and what the group shows
/// is worked out from the hub's own answers with it (`ConnectGate.show`), so that a sleep loses nothing and a second
/// Turn on cannot start beside the first. A turn that a quit cut off is kept in this Mac's settings and shows as its
/// row with Try again at the next launch (`ConnectGate.kept`).
@MainActor @Observable final class ConnectSwitchModel {
    private let hub: URL
    /// What the run does now.
    private(set) var run: ConnectGate.Run = .idle
    /// The key page: the policy lines to add where another tool keeps the policy, their Copy, and the reason that the
    /// last paste failed.
    private(set) var linesToAdd: String?
    private(set) var copied = false
    private(set) var failure: String?
    /// The token's calls run now: the key page's title moves.
    private(set) var preparing = false
    /// Counts each run that ended, so that the page reads `GET /ui/connect` again at once.
    private(set) var ended = 0
    /// Counts each opening of the key page: the answer of a token that he pasted on an opening before starts nothing.
    @ObservationIgnored private var opening = 0
    /// The stop is one that a quit cut off (`ConnectGate.kept`), which goes when he leaves the page.
    @ObservationIgnored private var cutOff = false
    /// The calls of his Tailscale token (`TailscaleFleetKey.connectNetwork`): the two policy lines, the tag on the
    /// hub's device, MagicDNS and HTTPS certificates. A test gives a stand-in. The token is an argument only: it is kept
    /// in no file, no Keychain item, no log and no value of this model.
    @ObservationIgnored var prepareNetwork: @Sendable (String) async throws -> ConnectNetworkAnswer

    init(hub: URL) {
        self.hub = hub
        // A turn that a quit cut off: its row with Try again (`ConnectGate.kept`).
        if let turn = ConnectGate.kept(hub) { run = .stopped(ConnectGate.cutOff(turn), turn); cutOff = true }
        // The hub's device in his tailnet is found by the host of the address that this Mac calls the hub by.
        let host = hub.host ?? ""
        prepareNetwork = { token in try await TailscaleFleetKey().connectNetwork(accessToken: token, hub: host) }
    }

    /// A step of the run is on its way.
    var running: Bool { run == .turningOn || run == .turningOff }

    /// The stop of a Turn off, for the row in the card of the approved "Connect an app".
    var offStop: ConnectStop? {
        if case .stopped(let stop, .off) = run { return stop }
        return nil
    }

    // MARK: Turn on

    /// Turn on: his Tailscale key page. Not while a step runs.
    func turnOn(store: FleetStore) {
        guard store.hub == hub, !running else { return }
        openKeyPage(store: store)
    }

    /// One opening of the key page, from Turn on and from a Try again that needs the token again. The calls of a token
    /// that he pasted on an opening before may still run: this opening is not busy with them, and their answer is not
    /// its answer (`send` compares `opening`).
    private func openKeyPage(store: FleetStore) {
        run = .keyPage
        opening += 1
        linesToAdd = nil; copied = false; failure = nil; preparing = false
        store.destination = .connectKey
    }

    /// Back on the key page: Settings › Servers, with nothing started. While the token's calls run, Back ends the turn
    /// too: what they wrote in his network stays (the lines, the tag), and no step starts on the hub's machine (`send`).
    func back(store: FleetStore) {
        if run == .keyPage { run = .idle }
        linesToAdd = nil; copied = false; failure = nil
        store.destination = .settings(.servers)
    }

    /// He left Settings › Servers: a stop that Try again cannot repair goes with the page, so that Turn on is there
    /// again after his agent put the server right. A stop with Try again stays.
    /// A turn that a quit cut off goes too, with its mark: he saw its row, and he may have changed his mind.
    func left() {
        guard case .stopped(let stop, _) = run, !stop.retries || cutOff else { return }
        run = .idle
        if cutOff { ConnectGate.keep(nil, for: hub); cutOff = false }
    }

    /// The hub serves connected apps: a Turn on that stopped, or that a quit cut off, has nothing left to do, so its
    /// stop goes (the page shows the two groups then, and no row of it).
    func served() {
        if case .stopped(_, .on) = run {
            run = .idle
            cutOff = false
            ConnectGate.keep(nil, for: hub)
        }
    }

    /// The pasted token: its calls, then the page goes back and the steps go on by themselves. Lines to add stay on the
    /// page, with the field, for a paste of a key again.
    func send(_ token: String, store: FleetStore) async {
        guard store.hub == hub, run == .keyPage, !preparing else { return }
        preparing = true
        failure = nil
        linesToAdd = nil; copied = false
        let opened = opening
        // Only its own opening: after Back and Turn on again, a paste on the new opening is busy by itself.
        defer { if opened == opening { preparing = false } }
        do {
            let answer = try await prepareNetwork(token)
            // He pressed Back meanwhile (also when he then pressed Turn on again), or the store moved to another hub:
            // nothing more starts.
            guard store.hub == hub, run == .keyPage, opened == opening, store.destination == .connectKey else { return }
            switch answer {
            case .done:
                linesToAdd = nil; copied = false
                store.destination = .settings(.servers)
                start(.on, store: store)
            case .addLines(let lines):
                linesToAdd = lines; copied = false
            }
        } catch {
            guard store.hub == hub, run == .keyPage, opened == opening else { return }
            failure = HubError.said(error) ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func copyLines() {
        guard let linesToAdd else { return }
        copyMessage(linesToAdd)
        copied = true
    }

    // MARK: Try again and Turn off

    /// Try again: every step of the run that stopped again, each of which skips what is done. A stop that needs the
    /// token again opens his key page, because the token is not kept. A row that the hub's own answer made, with no
    /// run of this launch behind it (`ConnectGate.show`, `ConnectState.stopped`), is a Turn on that did not end: its
    /// Try again runs the steps of a Turn on.
    func tryAgain(store: FleetStore) {
        guard store.hub == hub, !running else { return }
        guard case .stopped(let stop, let turn) = run else {
            if run == .idle { start(.on, store: store) }
            return
        }
        cutOff = false
        if turn == .on, stop.keyAgain {
            openKeyPage(store: store)
        } else {
            start(turn, store: store)
        }
    }

    /// Turn off, after its confirmation in the card.
    func turnOff(store: FleetStore) {
        guard store.hub == hub, !running else { return }
        // As Try again does: this is a new turn, and a stop of it is its own (a Turn off from the row of a Turn on
        // that a quit cut off would else lose its "did not turn off" row when he leaves the page, `left`).
        cutOff = false
        start(.off, store: store)
    }

    // MARK: the run

    private func start(_ turn: ConnectTurn, store: FleetStore) {
        guard !running else { return }
        run = turn == .on ? .turningOn : .turningOff
        ConnectGate.keep(turn, for: hub)        // until it ends: a quit meanwhile shows its row at the next launch
        let steps = self.steps(store)
        let hub = hub
        Task {
            let stop = turn == .on ? await ConnectGate.turnOn(steps) : await ConnectGate.turnOff(steps)
            run = stop.map { .stopped($0, turn) } ?? .idle
            ConnectGate.keep(nil, for: hub)
            ended += 1
        }
    }

    /// The steps on this hub, and on no other: a store that moved to another hub meanwhile stops them.
    private func steps(_ store: FleetStore) -> ConnectGate.Steps {
        let hub = hub
        return ConnectGate.Steps(
            rootStep: { @MainActor turn in
                guard store.hub == hub else { throw HubError.invalidResponse }
                return try await store.vaultModel().rootRun(ConnectGate.program(turn: turn), store: store)
            },
            setting: { @MainActor on in
                guard store.hub == hub, let database = store.state?.db else { throw HubError.invalidResponse }
                _ = try await HubClient().connectSettings(hub: hub, database: database, client: store.installation, on: on)
                await store.refresh()
            },
            ready: { @MainActor in store.hub != hub || ConnectGate.ready(features: store.state?.ui_features) },
            closed: { @MainActor in
                // The hub's own reason while it is on and does not work: one small read in each round of the wait.
                guard store.hub == hub, let database = store.state?.db else { return nil }
                return (try? await HubClient().connectState(hub: hub, database: database))?.stopped
            },
            isOn: { @MainActor in
                guard store.hub == hub, let database = store.state?.db else { return nil }
                return (try? await HubClient().connectState(hub: hub, database: database))?.on
            },
            wait: { @MainActor in _ = try await store.nap(5) })
    }
}

/// The group "Connect an app" while the feature is off, turns on, or did not turn on or off (`ConnectGate.show`).
struct ConnectAppOffer: View {
    let show: ConnectGate.Show
    /// The hub takes a write now: else no button, never a grey one.
    let canAct: Bool
    let turnOn: () -> Void
    let tryAgain: () -> Void
    let report: () -> Void
    /// Turn off while the feature is on and does not work (`ConnectGate.offersTurnOff`): on the heading, as in the
    /// working state, behind the same confirmation in the card. Nil: no Turn off here.
    var turnOff: (() -> Void)?
    /// The confirmation of that Turn off is open.
    var confirmingOff = false
    var askOff: () -> Void = {}
    var cancelOff: () -> Void = {}

    var body: some View {
        FormSection("Connect an app") {
            if case .stopped(let stop, let turn) = show {
                // The confirmation over the row, as it stands over the address in the working state.
                if confirmingOff, let turnOff {
                    ConnectAppTurnOff(canAct: canAct, cancel: cancelOff, turnOff: turnOff)
                }
                ConnectStopRow(title: turn == .on ? String(l10n: "Connected apps did not turn on") : String(l10n: "Connected apps did not turn off"),
                               stop: stop, canAct: canAct, tryAgain: tryAgain, report: report)
            } else {
                FormEmpty("No connected apps yet", symbol: "powerplug")
            }
        } accessory: {
            // On the group's own heading, where Add device stands on its own: only while it can act, never grey.
            if show == .turningOn {
                LoadingLine(String(l10n: "Turning on…"), waits: false).fixedSize()
            } else if show == .turningOff {
                LoadingLine(String(l10n: "Turning off…"), waits: false).fixedSize()
            } else if show == .off(turnOn: true), canAct {
                Button("Turn on", action: turnOn).buttonStyle(FleetOutlineButtonStyle())
                    .accessibilityIdentifier("connect-turn-on")
            } else if turnOff != nil, canAct, !confirmingOff {
                Button("Turn off connected apps", action: askOff).buttonStyle(FleetOutlineButtonStyle())
                    .accessibilityIdentifier("connect-turn-off")
            }
        }
        .font(FleetStyle.body).foregroundStyle(FleetStyle.text)
    }
}

/// The failure row of this page ("The devices are unavailable"): the mark, the words, the reason in orange, and the
/// one thing to do. Also the row of a Turn off that stopped, in the card of "Connect an app".
struct ConnectStopRow: View {
    let title: String
    let stop: ConnectStop
    let canAct: Bool
    let tryAgain: () -> Void
    let report: () -> Void

    var body: some View {
        FormRow(title, symbol: "exclamationmark.circle", warning: stop.words) {
            if stop.retries {
                if canAct {
                    Button("Try again", action: tryAgain).buttonStyle(FleetOutlineButtonStyle())
                        .accessibilityIdentifier("connect-try-again")
                }
            } else {
                Button("Report a problem", action: report).buttonStyle(FleetOutlineButtonStyle())
                    .accessibilityIdentifier("connect-report")
            }
        }
    }
}

/// **His Tailscale key, once: the network setup's own page** (`FirstRunView.key`): the steps at Tailscale over the
/// field, the field that sends by itself when a token is pasted, and the lines to add when another tool keeps the
/// policy (`PolicyLines`). The token is in no file, no Keychain item and no log: the field's text is this page's own
/// state, and it is emptied when it is sent.
struct ConnectAppKeyStep: View {
    @Binding var text: String
    /// The policy lines to add where another tool keeps the policy.
    var linesToAdd: String?
    var copied = false
    var failure: String?
    var busy = false
    let back: () -> Void
    let send: () -> Void
    let copy: () -> Void

    var body: some View {
        SetupPage {
            SetupBack(action: back)
        } step: {
            SetupStep(title: busy ? String(l10n: "Connecting your network") : String(l10n: "Your Tailscale key"), waits: busy) { NetworkMark() } content: {
                if !busy {
                    SetupSteps.tailscaleKey
                    PasteField(placeholder: String(l10n: "Paste it here"), text: $text, accepts: { $0.hasPrefix("tskey-api-") }, send: send)
                        .accessibilityIdentifier("connect-tailscale-key")
                }
                if let linesToAdd { PolicyLines(lines: linesToAdd, copied: copied, copy: copy) }
                if let failure { SetupWarning(failure) }
            }
        }
    }
}

/// The key page of Turn on (`Destination.connectKey`), on the store's run.
struct ConnectAppKeyPage: View {
    @Bindable var store: FleetStore
    @Bindable var model: ConnectSwitchModel
    /// The pasted token, in this page's state only.
    @State private var text = ""

    var body: some View {
        ConnectAppKeyStep(text: $text, linesToAdd: model.linesToAdd, copied: model.copied, failure: model.failure,
                          busy: model.preparing, back: { model.back(store: store) },
                          send: {
                              let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
                              text = ""
                              Task { await model.send(token, store: store) }
                          },
                          copy: { model.copyLines() })
        .onExitCommand { model.back(store: store) }
    }
}

/// Turn off, behind one confirmation in the group's card, as Revoke has.
struct ConnectAppTurnOff: View {
    let canAct: Bool
    let cancel: () -> Void
    let turnOff: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(IconMetrics.symbol(13)).foregroundStyle(.orange)
            Text("Every connected app stops at once.")
                .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Cancel", action: cancel).buttonStyle(FleetOutlineButtonStyle())
                .accessibilityIdentifier("connect-turn-off-cancel")
            if canAct {
                Button("Turn off", action: turnOff).buttonStyle(FleetDangerButtonStyle())
                    .accessibilityIdentifier("connect-turn-off-confirm")
            }
        }
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 12)
    }
}
