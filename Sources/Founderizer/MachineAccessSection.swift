import FleetCore
import SwiftUI

/// **The one control a machine with no connection on record lacks**: the owner tells the fleet how he reaches it,
/// and the fleet keeps it (`POST /ui/team/access`, owner feature `machine_access`).
///
/// A machine whose connection is already on record gets nothing from this file. The owner, 20 October 2026: "not
/// even sentences, just a check or a cross, and on hover probably show the detail", and no row that reports only
/// that everything is fine. So this is a cross that carries its action, and it is there only while there is
/// something to ask for.
///
/// **Why the record and not this Mac's own fields.** `MachineConnectionFields` on a server's page asks for a
/// connection too, and keeps it in this Mac's defaults (`InstallTargets`): the hub never sees it, no agent reads
/// it, and a new Mac starts again with nothing. The fleet's own record is `team.json`'s `access` map — what
/// `GET /ui/machines` reports as `access.ssh`, what `machine_readiness` turns into `no_ssh`, and what every
/// screen that says how a machine is reached reads. Until this route every writer of it wrote at creation time and
/// never again — the hub installer, a server's join (`root`, Linux only), the local onboarding executor — so the
/// Studio stood in the record with no connection while the owner reached it as its own user every day.
struct MachineAccessRecord: View {
    @Bindable var store: FleetStore
    let reading: MachineStatus
    /// Read the machine again after a write, so the row goes as soon as the record is there.
    let refresh: () async -> Void

    @State private var asking = false
    @State private var form = MachineAccessForm()
    /// The team.json the write goes against: its version, and what the hub says about this machine.
    @State private var team: TeamSnapshot?
    @State private var busy = false
    @State private var message: (text: String, warning: Bool)?
    /// The system's own words for the last write the hub did not answer: behind its line, never in it.
    @State private var cause: String?
    @State private var client = HubClient()

    private var machine: String { reading.machine }
    /// One rule, in FleetCore, for whether this section exists at all (`MachineAccessForm.isAsked`).
    private var asked: Bool { MachineAccessForm.isAsked(of: reading, features: store.state?.ui_features) }
    /// The OS user this machine's agents run as, as its own helper reports it: with `root`, the only user the
    /// fleet may be recorded as.
    private var workerUser: String? { team?.machines?[machine]?.worker_user }
    private var refused: String? { form.notAllowed(workerUser: workerUser) }

    var body: some View {
        // Nothing on a hub without the route, and nothing for a machine whose connection the fleet already has.
        if asked {
            FormSection(asking ? "How the fleet reaches \(machine)" : nil, footer: asking ? Self.footer : nil) {
                if asking { fields } else { missing }
            }
        }
    }

    /// The cross, and the one thing he presses. The sentence is behind the mark, which is the rule for every row
    /// of this app that states a fact.
    @ViewBuilder private var missing: some View {
        FormMarkRow(title: "Connection", state: .bad, symbol: "network",
                    words: "Not on record",
                    detail: MachineReach.nothingOnRecord(machine)
                        + " Without it no agent can be added to this server, and nothing here can reach it.",
                    act: store.canWrite ? ("Record it", { open() }) : nil,
                    whoActs: store.canWrite ? nil
                        : "Founderizer is waiting for the hub. The record can be written when it answers.",
                    identifier: "machine-access-missing")
    }

    @ViewBuilder private var fields: some View {
        FormRow("User", symbol: "person",
                detail: workerUser.map { "This server's agents run as \($0), so the fleet may be recorded as "
                    + "\($0) or as root." } ?? "The user you reach this server as over SSH.",
                warning: refused) {
            HStack(spacing: 8) {
                TextField("", text: $form.user).fleetField().frame(width: 110)
                    .accessibilityIdentifier("machine-access-user")
                TextField(text: $form.port, prompt: Text(verbatim: "")) { Text("22") }
                    .fieldPlaceholder("22", shows: form.port.isEmpty).fleetField().frame(width: 60)
                    .accessibilityIdentifier("machine-access-port")
            }
        }
        FormRow("Screen Sharing", symbol: "display",
                detail: "Whether this server answers Screen Sharing, so the app offers its screen.") {
            Toggle("Screen Sharing", isOn: $form.screenSharing).toggleStyle(.switch).controlSize(.small)
                .labelsHidden().accessibilityIdentifier("machine-access-screen")
        }
        FormRow("Put it on record", symbol: "square.and.arrow.down",
                detail: busy ? "Writing it to your fleet…" : form.problem,
                warning: message?.warning == true ? message?.text : nil) {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel") { asking = false; message = nil }
                    .buttonStyle(FleetOutlineButtonStyle()).disabled(busy)
                    .accessibilityIdentifier("machine-access-cancel")
                Button("Record") { Task { await record() } }
                    .buttonStyle(FleetPrimaryButtonStyle())
                    .disabled(busy || !store.canWrite || !form.isValid || refused != nil || team == nil)
                    .accessibilityIdentifier("machine-access-save")
            }
        }
        // The system's own words of an unanswered write are behind its orange line.
        .help(message?.text == Self.unanswered ? cause ?? "" : "")
        .accessibilityValue(message?.text == Self.unanswered ? cause ?? "" : "")
        if let message, !message.warning {
            Text(message.text).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("machine-access-status")
        }
    }

    private static let footer = "Founderizer keeps this in your fleet's own team.json, so every screen and every "
        + "agent reads the same connection. It holds no password and no key: the key stays on this Mac."

    private func open() {
        asking = true; message = nil
        form = MachineAccessForm()
        Task { await readTeam() }
    }

    private func readTeam() async {
        guard let db = store.state?.db else { return }
        let hub = store.hub
        do {
            let fresh = try await client.team(hub: hub, database: db)
            guard !Task.isCancelled, store.hub == hub, store.state?.db == db else { return }
            team = fresh
        } catch {
            guard !Task.isCancelled else { return }
            cause = Self.cause(error); message = (Self.reason(error), true)
        }
    }

    /// One write against the team.json version this section read. When the team changed meanwhile (409) it reads
    /// again and writes the same thing once more, as the GitHub section does.
    private func record() async {
        guard let db = store.state?.db, var current = team, form.isValid, refused == nil else { return }
        let hub = store.hub, client = self.client, installation = store.installation
        busy = true; message = nil
        defer { busy = false }
        do {
            for attempt in 1...2 {
                do {
                    _ = try await client.recordMachineAccess(hub: hub, database: db, client: installation,
                                                             machine: machine, sha256: current.sha256, form: form)
                    message = ("The fleet reaches \(machine) as \(form.trimmedUser) from now on.", false)
                    asking = false
                    break
                } catch HubError.refusal(409, _) where attempt == 1 {
                    current = try await client.team(hub: hub, database: db)
                    team = current
                }
            }
        } catch { cause = Self.cause(error); message = (Self.reason(error), true) }
        await refresh()
    }

    private static func reason(_ error: Error) -> String {
        if case HubError.refusal(_, let text) = error {
            return "Not done. The hub said: \(text.hasSuffix(".") ? text : text + ".")"
        }
        if error is URLError { return unanswered }
        return error.localizedDescription
    }

    /// A write that the hub did not answer, in our words: the system's own are `cause`, on hover.
    private static let unanswered = "The hub did not answer. The record can still have arrived: look at this server "
        + "before you try again."
    private static func cause(_ error: Error) -> String? { error is URLError ? error.localizedDescription : nil }
}
