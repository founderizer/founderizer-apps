import AppKit
import FleetCore
import SwiftUI

/// The connected apps of Settings › Servers (hub feature `connected_apps`; the owner's yes of 12 November 2026 to the
/// picture): under "Your devices", two groups of the page. "Connected apps": one row for each open connection, with its
/// mark, its name, its level and its last use, and Revoke behind one confirmation in the same row. "Connect an app":
/// the hub's public MCP address with a copy mark, a choice of Read or Act with Read chosen, and a one-time code.
///
/// **Nothing else**, apart from Turn off on the heading of "Connect an app", with its confirmation and its failure row in
/// that card (the owner's yes of 13 November 2026 to the pictures 2e and 2f; the run is `ConnectSwitchModel`). While a
/// read fails or no app is connected, the group draws nothing: no heading, no empty card, no failure row and no line. A
/// hub without the feature, or one that refuses `/ui/connect`, shows no group at all. Turn on, its wait and its failure
/// row are the group of `ConnectAppOffer`, while the hub names `connect_offer`.
///
/// **One code for each time that the group comes on screen** (the decision of the review, 12 November 2026): the page
/// makes it when it opens, and keeps it until it is used or ends; then it makes a new one while the app is in front, and
/// also when the owner changes the choice (`keepCode`). The code is in this page's state only: never in a note, a file,
/// a log or the pasteboard.
@MainActor @Observable final class ConnectedAppsModel {
    /// The last answer of `GET /ui/connect`, or nil while none came or after a read that failed.
    var state: ConnectState?
    /// The level of the next code. Read when the page opens.
    var level = "read"
    /// The code that this page made, while it works.
    var made: MadeConnectCode?
    /// The connection whose Revoke waits for the second click.
    var confirming: Int?
    /// A write of this page is on its way: its buttons go until it is answered.
    var busy = false
    /// Turn off waits for its second click, in the card of "Connect an app".
    var confirmingOff = false

    /// The hub and the generation that this page reads. A change of either starts the page again.
    private var reads: (hub: URL, database: String)?
    private var making = false
    private var again = false

    /// A code of this page, with the connections that were open when the hub made it: a connection that is not one of
    /// them came with this code, so the code is used.
    struct MadeConnectCode: Equatable {
        let code: String
        let level: String
        let expires: Double
        let known: Set<Int>
    }

    /// This visit asked for its first code (the group came on screen).
    private var asked = false
    /// The code of this visit ended or was used, or a new one was refused: the group stays, its box shows nothing, and
    /// a new code comes when the app is active (in front) again.
    var waits = false

    var connections: [AppConnection] { state?.connections ?? [] }
    /// The group "Connected apps" has rows.
    var showsConnected: Bool { !connections.isEmpty }
    /// The group "Connect an app": the feature is on, the hub knows its address, and a code works or waits for the app
    /// to come to the front.
    func showsConnect(now: Double) -> Bool {
        state?.on == true && state?.address != nil && (code(now: now) != nil || waits)
    }
    /// The code to show: one that works on the hub's clock.
    func code(now: Double) -> MadeConnectCode? { made.flatMap { $0.expires > now ? $0 : nil } }
    func draws(now: Double) -> Bool { showsConnected || showsConnect(now: now) }

    /// The page's loop while it shows: the state every 15 seconds (sooner when the hub's live changes wake the store),
    /// and a new code when the old one was used or ended. Nothing runs on a hub that names neither `connected_apps` nor
    /// `connect_offer`; a hub that names only `connect_offer` is read for Turn on and its wait (`ConnectGate.show`), and
    /// gets no code.
    func run(store: FleetStore) async {
        let features = store.state?.ui_features ?? []
        guard features.contains(ConnectedApps.feature) || features.contains(ConnectedApps.offer),
              let database = store.state?.db else {
            reset(); return
        }
        if reads?.hub != store.hub || reads?.database != database { reset() }
        reads = (store.hub, database)
        while !Task.isCancelled {
            await read(store: store)
            if store.state?.ui_features?.contains(ConnectedApps.feature) == true {
                await keepCode(store: store, active: NSApplication.shared.isActive)
            }
            do { _ = try await store.nap(15) } catch { return }
        }
    }

    /// The app came to the front: a code that ended meanwhile is replaced now.
    func activated(store: FleetStore) async {
        guard reads != nil, isFor(store) else { return }
        await keepCode(store: store, active: true, activation: true)
    }

    /// He changed the choice: a new code at that level replaces the open one.
    func choose(_ level: String, store: FleetStore) async {
        // Not while the hub takes no write: the choice stays at the level of the code that shows.
        guard ConnectedApps.levels.contains(level), level != self.level, isFor(store), store.canWrite else { return }
        self.level = level
        await makeCode(store: store)
    }

    /// Revoke, after its confirmation in the row.
    func revoke(_ connection: AppConnection, store: FleetStore) async {
        guard let reads, isFor(store), store.canWrite, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await HubClient().connectRevoke(hub: reads.hub, database: reads.database, client: store.installation,
                                                    id: connection.id)
        } catch {
            // No line for a refusal (it is not in what he approved): the row stays while the hub keeps it open.
        }
        confirming = nil
        await read(store: store)
    }

    func isFor(_ store: FleetStore) -> Bool { reads?.hub == store.hub && reads?.database == store.state?.db }

    private func reset() {
        state = nil; made = nil; confirming = nil; level = "read"; reads = nil; asked = false; waits = false
        confirmingOff = false
    }

    private func read(store: FleetStore) async {
        guard let reads, isFor(store) else { return }
        do {
            let fresh = try await HubClient().connectState(hub: reads.hub, database: reads.database)
            guard isFor(store) else { return }
            state = fresh
            if let confirming, !fresh.connections.contains(where: { $0.id == confirming }) { self.confirming = nil }
        } catch {
            // A hub without the route, a 409, or no answer: nothing of it shows, and the next round reads again.
            guard isFor(store) else { return }
            state = nil
            confirming = nil
        }
    }

    /// **No new code while he is not there** (the review, 12 November 2026): a code only when the group comes on
    /// screen, when he changes the choice (`choose`), and when a code ended or was used while the app is active. A code
    /// that ended while the app is in the background goes from the box, and the next one comes when the app is active
    /// again (`activated`). Each code is a write to the hub.
    private func keepCode(store: FleetStore, active: Bool, activation: Bool = false) async {
        guard let state, state.on, state.address != nil else { return }
        let now = store.state?.time ?? Date().timeIntervalSince1970
        if let made {
            if made.expires > now, Set(state.connections.map(\.id)).isSubset(of: made.known) { return }
            self.made = nil
            waits = true
            if active { await makeCode(store: store) }
        } else if !asked {
            asked = true
            await makeCode(store: store)
        } else if waits, activation {
            await makeCode(store: store)
        }
    }

    /// One code at a time: a choice that changes while a code is on its way makes one more after it.
    private func makeCode(store: FleetStore) async {
        guard !making else { again = true; return }
        making = true
        defer { making = false }
        repeat {
            again = false
            guard let reads, isFor(store), store.canWrite, let state, state.on else { return }
            let level = self.level
            let known = Set(state.connections.map(\.id))
            do {
                let answer = try await HubClient().connectCode(hub: reads.hub, database: reads.database,
                                                               client: store.installation, level: level)
                guard isFor(store) else { return }
                if let code = answer.code {
                    made = MadeConnectCode(code: code, level: answer.level, expires: answer.expires, known: known)
                    waits = false
                } else {
                    made = nil
                    waits = true
                }
            } catch {
                // The open code on the hub is the one that this page shows, so the choice goes back to its level.
                // With no code, the box waits for the app's next return to the front.
                guard isFor(store) else { return }
                if let made {
                    if made.level != level, !again { self.level = made.level }
                } else {
                    waits = true
                }
            }
        } while again
    }
}

/// The two groups, drawn only while one of them has something to show (`ConnectedAppsModel.draws`), so that the page
/// gets no empty block.
struct ConnectedAppsGroups: View {
    @Bindable var model: ConnectedAppsModel
    /// The hub's time of the last state.
    let now: Double
    /// The hub takes a write now, and the page reads this hub: else no Revoke and no choice.
    let canAct: Bool
    let choose: (String) -> Void
    let revoke: (AppConnection) -> Void
    /// Turn off (the build specification of the MCP address, section 7, "Off"; the owner's yes of 13 November 2026 to
    /// the pictures 2e and 2f), behind one confirmation in the card. Nil: no Turn off now (a step runs).
    var turnOff: (() -> Void)?
    /// A Turn off that stopped while the hub still serves the feature: its row stands first in the card.
    var offStop: ConnectStop?
    /// Report a problem, for a Turn off that stopped on work that the machine needs.
    var report: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: FleetSpace.block) {
            if model.showsConnected {
                FormSection("Connected apps") {
                    ForEach(model.connections) { row($0) }
                }
            }
            if model.showsConnect(now: now), let address = model.state?.address {
                FormSection("Connect an app") {
                    // A Turn off that stopped, then the confirmation, under the heading's Turn off that opened it.
                    if let offStop, let turnOff {
                        ConnectStopRow(title: "Connected apps did not turn off", stop: offStop,
                                       canAct: canAct && !model.busy, tryAgain: turnOff, report: report)
                    } else if model.confirmingOff, let turnOff {
                        ConnectAppTurnOff(canAct: canAct && !model.busy, cancel: { model.confirmingOff = false },
                                          turnOff: { model.confirmingOff = false; turnOff() })
                    }
                    addressRow(address)
                    levelRow
                    codeRow(model.code(now: now))
                } accessory: {
                    // On the group's own heading, as Add device is on its own: only while it can act, never grey.
                    if turnOff != nil, canAct, !model.busy, !model.confirmingOff, offStop == nil {
                        Button("Turn off") { model.confirmingOff = true }.buttonStyle(FleetOutlineButtonStyle())
                            .accessibilityIdentifier("connect-turn-off")
                    }
                }
            }
        }
        .font(FleetStyle.body).foregroundStyle(FleetStyle.text)
    }

    // MARK: Connected apps

    /// One connection: its mark in the tile of a device's row, so that its name stands in a device name's column; its
    /// name over its level and its last use, and Revoke at the right. The confirmation opens in the row itself, as
    /// Remove of a device does.
    private func row(_ connection: AppConnection) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                IconTile(symbol: "powerplug")
                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.name).font(FormMetrics.title).foregroundStyle(FleetStyle.text)
                    Text(ConnectedApps.detail(connection, now: now)).font(FormMetrics.detail)
                        .foregroundStyle(FleetStyle.muted)
                }
                Spacer(minLength: 12)
                // Only while it can act, never grey: not while the confirmation is open or a write is on its way.
                if canAct, !model.busy, model.confirming != connection.id {
                    Button("Revoke") { model.confirming = connection.id }
                        .buttonStyle(FleetOutlineButtonStyle())
                        .accessibilityIdentifier("connected-app-revoke-\(connection.id)")
                }
            }
            if model.confirming == connection.id { confirmation(connection) }
        }
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 10).frame(minHeight: FormMetrics.twoLineRow)
        .accessibilityElement(children: .contain).accessibilityIdentifier("connected-app-\(connection.id)")
    }

    /// Revoke, behind one confirmation in the row, in the words of Remove's confirmation of a device.
    private func confirmation(_ connection: AppConnection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(IconMetrics.symbol(13)).foregroundStyle(.orange)
            Text("Its key stops working at once. \(connection.name) comes back only with a new code.")
                .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Cancel") { model.confirming = nil }.buttonStyle(FleetOutlineButtonStyle())
                .accessibilityIdentifier("connected-app-revoke-cancel")
            if canAct, !model.busy {
                Button("Revoke") { revoke(connection) }.buttonStyle(FleetDangerButtonStyle())
                    .accessibilityIdentifier("connected-app-revoke-confirm")
            }
        }
    }

    // MARK: Connect an app

    /// The hub's public MCP address, monospaced as a name in code on a row, and its copy mark.
    private func addressRow(_ address: String) -> some View {
        HStack(spacing: 12) {
            Text(address).font(FormMetrics.text.monospaced()).foregroundStyle(FleetStyle.text)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                .accessibilityIdentifier("connect-address")
            Spacer(minLength: 12)
            IconButton(symbol: "doc.on.doc", words: "Copy") { copyMessage(address) }
                .accessibilityIdentifier("connect-copy")
        }
        .padding(.horizontal, FormMetrics.rowInset).frame(minHeight: FormMetrics.row)
    }

    /// Read or Act, Read chosen when the page opens. A new choice makes a new code; while the hub takes no write, a
    /// click changes nothing.
    private var levelRow: some View {
        HStack {
            FleetSegmented("Level", selection: Binding(get: { model.level }, set: { choose($0) }),
                           options: ConnectedApps.levels.map { FleetOption($0, ConnectedApps.levelWord($0)) })
                .fixedSize()
                .accessibilityIdentifier("connect-level")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, FormMetrics.rowInset).frame(minHeight: FormMetrics.row)
    }

    /// The code in the style of a device's code: large, on one line, in its inner box, as the hub gives it. No words
    /// with it. While a new code waits for the app to come to the front, the box keeps its height and shows nothing.
    private func codeRow(_ made: ConnectedAppsModel.MadeConnectCode?) -> some View {
        Text(made?.code ?? "ABCD-EFGH-JKLM").font(FormMetrics.oneTimeCode).foregroundStyle(FleetStyle.text)
            .textSelection(.enabled).fixedSize().opacity(made == nil ? 0 : 1).accessibilityHidden(made == nil)
            .accessibilityIdentifier("connect-code")
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(FleetStyle.canvas, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
            .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner).strokeBorder(FleetStyle.line, lineWidth: 0.5))
            .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 12)
    }
}
