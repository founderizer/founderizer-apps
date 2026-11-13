import AppKit
import FleetCore
import SwiftUI

struct MachineDetails: View {
    @Bindable var store: FleetStore
    let agent: String
    /// True where a sign-in this machine still waits for is on the face of the page already — a server's page,
    /// which puts the owner's own next step after an install where it says that step is needed. The card is then
    /// here only for a machine that is signed in, where signing in again is a rare thing to want.
    var signInOnFace = false
    @State private var client = HubClient()
    /// The machine, from the machines' reading the store keeps (`FleetStore.reading`), which the agent's panel and its
    /// Settings read too: it shows in the first frame, and the read that starts then changes only what changed.
    private var reading: MachineStatus? { (store.reading("machines") as MachineList?)?.machines.first { $0.agent == agent } }
    @State private var error: String?
    @State private var checking = false
    /// What stopped the read. While the hub does not answer nothing is read, so a machine not read yet says it is
    /// unavailable then, and never "Reading the server…" for as long as the hub is down.
    private var failure: String? { error ?? (reading == nil && store.connectionError != nil ? Self.unavailable : nil) }
    private static let unavailable = String(l10n: "Server status is unavailable.")
    private var fresh: Bool { store.isFresh && reading?.isCurrent(at: store.state?.time ?? 0) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let reading {
                if reading.sshURL != nil || reading.screenSharingURL != nil { MachineAccessButtons(reading: reading, fresh: fresh) }
                // The one control a machine with no connection on record lacks. It draws nothing for a machine
                // that has one, which is the owner's rule: no row that reports only that everything is fine.
                MachineAccessRecord(store: store, reading: reading, refresh: refresh)
                FormSection("Server") {
                    // Is this reading current? A yes-or-no fact, so a mark, with the time it was read behind it.
                    FormMarkRow(title: reading.os.name ?? String(l10n: "System not reported"), state: fresh ? .good : .warn,
                                words: fresh ? String(l10n: "Current") : String(l10n: "Last reading"),
                                detail: String(l10n: "Read \(fleetDate(reading.reported_at))."),
                                whoActs: fresh ? nil : String(l10n: "The server sends its own reading every few minutes."),
                                identifier: "machine-reading")
                    // A revision is a value and not a state: a mark cannot carry one, so this row keeps its words.
                    FormRow("Founderizer") { value(reading.revision.map { String($0.prefix(8)) } ?? String(l10n: "Not reported")) }
                    if let runtimes = reading.runtimes?.byName, !runtimes.isEmpty {
                        ForEach(runtimes.keys.sorted(), id: \.self) { name in
                            let row = ProviderRow(name: name, runtime: runtimes[name], reading: reading)
                            switch row.answer {
                            case .mark(let state, let words, let whoActs):
                                FormMarkRow(title: row.title, state: state, words: words, detail: String(l10n: "On \(reading.machine)."),
                                            whoActs: whoActs, identifier: "machine-provider-\(name)")
                            case .notSetUp(let words):
                                FormRow(row.title) { value(words) }.accessibilityIdentifier("machine-provider-\(name)")
                            }
                        }
                        if let loaded = reading.runtime.name { FormRow("Loaded provider") { value(providerName(loaded)) } }
                    } else {
                        FormRow("Runtime") { value(reading.runtime.version ?? String(l10n: "Not reported")) }
                        FormMarkRow(title: String(l10n: "Signed in"), state: Servers.onOffMark(reading.runtime.signed_in),
                                    words: yesNo(reading.runtime.signed_in),
                                    detail: String(l10n: "As Founderizer on \(reading.machine) last read it."),
                                    whoActs: reading.runtime.signed_in == false
                                        ? String(l10n: "Signing in is your own step: the Sign in card below takes it.") : nil,
                                    identifier: "machine-signed-in")
                    }
                }
                if !(signInOnFace && reading.waitsForSignIn) {
                    MachineSignInSection(store: store, agent: agent, reading: reading, fresh: fresh, refresh: refresh)
                }
                FormSection("Security") {
                    FormMarkRow(title: String(l10n: "Private network"), state: Servers.onOffMark(reading.security.tailscale),
                                words: yesNo(reading.security.tailscale),
                                detail: String(l10n: "Tailscale, which every server of your fleet is reached over."),
                                whoActs: reading.security.tailscale == false ? onTheMachine : nil,
                                identifier: "machine-tailnet")
                    FormMarkRow(title: String(l10n: "Firewall"),
                                state: Servers.onOffMark(reading.security.firewall.map { $0 == "active" }),
                                words: reading.security.firewall?.capitalized ?? String(l10n: "Not reported"),
                                detail: String(l10n: "The server's own firewall, as it reported it."),
                                whoActs: reading.security.firewall == "inactive" ? onTheMachine : nil,
                                identifier: "machine-firewall")
                    if store.state?.ui_features?.contains("vault_isolation") == true {
                        FormMarkRow(title: String(l10n: "Vault token"), state: Servers.onOffMark(reading.security.vault?.isolated),
                                    words: reading.security.vault?.isolated
                                        .map { $0 ? String(l10n: "Protected") : String(l10n: "Not isolated") } ?? String(l10n: "Not configured"),
                                    detail: String(l10n: "Whether this server's vault keeps its token apart from the agents."),
                                    whoActs: reading.security.vault?.isolated == false
                                        ? String(l10n: "Set up this server's vault before using logins here.") : nil,
                                    identifier: "machine-vault")
                    }
                    if reading.os.name?.hasPrefix("macOS") != true {
                        FormMarkRow(title: String(l10n: "Security updates"),
                                    state: Servers.onOffMark(reading.security.unattended_upgrades),
                                    words: reading.security.unattended_upgrades
                                        .map { $0 ? String(l10n: "Automatic") : String(l10n: "Not automatic") } ?? String(l10n: "Not reported"),
                                    detail: String(l10n: "Whether the server installs its own security updates."),
                                    whoActs: reading.security.unattended_upgrades == false ? onTheMachine : nil,
                                    identifier: "machine-updates")
                        // The restart itself is on that machine's own server page, which has the connection for it.
                        FormMarkRow(title: String(l10n: "Waiting for a restart"),
                                    state: reading.security.reboot_required == true ? .warn
                                        : reading.security.reboot_required == false ? .good : .unknown,
                                    words: reading.security.reboot_required == true ? String(l10n: "Yes")
                                        : reading.security.reboot_required == false ? String(l10n: "No") : String(l10n: "Not reported"),
                                    detail: pendingWords(reading.security.pending_security),
                                    act: reading.security.reboot_required == true
                                        ? (String(l10n: "Open its server"), { store.destination = .server(reading.machine) }) : nil,
                                    identifier: "machine-restart-needed")
                    }
                }
                FormSection("Maintenance") {
                    let failed = reading.update.state == "failed"
                    FormRow("Founderizer update", detail: failed ? nil : lines(updateLabel(reading.update.state), reading.update.detail),
                            warning: failed ? lines(updateLabel(reading.update.state), reading.update.detail) : nil) {
                        // One rule, in FleetCore, for the helpers this route takes: a server's page offers the
                        // owner's own Mac for the rest, and no helper gets two ways to do one thing.
                        if reading.updatesThroughHub(leads: store.state?.ui_features?.contains("leads") == true) {
                            Button("Update Founderizer", systemImage: "arrow.down.circle") {
                                Task { await store.command(.machineUpdate(agent: agent)); await refresh() }
                            }.buttonStyle(FleetOutlineButtonStyle())
                                .disabled(!store.canWrite || !fresh || reading.updatePending || reading.update.state == "current")
                                .help("Updates when this worker is idle. Active tasks continue.")
                        }
                    }
                    if store.state?.ui_features?.contains("machine_check") == true {
                        let state = checking ? String(l10n: "Requesting…") : reading.check.map { checkLabel($0.state) }
                        let problem = !checking && ["failed", "offline"].contains(reading.check?.state ?? "")
                        FormRow("Server check", detail: problem ? nil : state,
                                warning: lines(problem ? state : nil, reading.check?.detail)) {
                            Button("Check server", systemImage: "arrow.clockwise") {
                                checking = true
                                Task {
                                    defer { checking = false }
                                    await store.command(.machineCheck(agent: agent))
                                    await refresh()
                                }
                            }.buttonStyle(FleetOutlineButtonStyle())
                                .disabled(!store.canWrite || checking || reading.check?.isPending == true)
                                .accessibilityIdentifier("check-machine-\(agent)")
                        }
                    }
                }
            } else if failure == nil { LoadingLine(String(l10n: "Reading the server…")) }
            // Not while the window's notice says the outage (`FleetStore.hubNoticeShows`; fix round 3, item 33: it is
            // said once); `failure` still keeps "Reading the server…" away while the hub is down.
            if let failure, !store.hubNoticeShows { Text(failure).foregroundStyle(.orange) }
        }.font(FormMetrics.detail)
        .task(id: "\(store.hub)/\(store.state?.db ?? "")") {
            error = nil
            while !Task.isCancelled {
                await refresh()
                let busy = reading?.check?.isPending == true || reading?.login?.isOpen == true
                do { try await store.nap(busy ? 2 : 15) } catch { return }
            }
        }
    }
    private func value(_ text: String) -> some View {
        Text(text).foregroundStyle(FleetStyle.muted).multilineTextAlignment(.trailing).textSelection(.enabled)
    }
    /// The given lines without empty ones, or nil when none is left.
    private func lines(_ parts: String?...) -> String? {
        let kept = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: "\n")
    }
    private func yesNo(_ value: Bool?) -> String { value.map { $0 ? String(l10n: "Yes") : String(l10n: "No") } ?? String(l10n: "Not reported") }

    /// How many security updates are waiting, behind the mark that says whether a restart is.
    private func pendingWords(_ pending: Int?) -> String {
        guard let pending else { return String(l10n: "The server reported no count of waiting updates.") }
        return pending == 1 ? String(l10n: "1 security update is installed and waiting.")
            : String(l10n: "\(pending) security updates are installed and waiting.")
    }

    /// What a cross says when the work is on the machine itself and no button of this app takes it.
    private var onTheMachine: String {
        String(l10n: "This is work on the server itself. Help → Report a problem sends it to one of your agents.")
    }
    private func checkLabel(_ state: String) -> String {
        switch state {
        case "requested": String(l10n: "Checking…")
        case "completed": String(l10n: "Check complete")
        case "offline": String(l10n: "Server offline")
        default: String(l10n: "Check failed")
        }
    }
    private func updateLabel(_ state: String?) -> String {
        switch state {
        case "current": String(l10n: "Up to date")
        case "behind": String(l10n: "Update available")
        case "requested", "waiting_idle": String(l10n: "Waiting for idle")
        case "updating": String(l10n: "Updating…")
        case "failed": String(l10n: "Update failed")
        default: String(l10n: "Version not reported")
        }
    }
    private func refresh() async {
        guard store.isFresh, let database = store.state?.db else { return }
        let hub = store.hub
        do {
            let list = try await client.machines(hub: hub, database: database)
            guard !Task.isCancelled, store.hub == hub, store.state?.db == database else { return }
            store.keep(list, as: "machines"); error = nil
            if reading == nil { error = String(l10n: "This server is not registered.") }
        } catch { if !Task.isCancelled { self.error = HubError.said(error) ?? Self.unavailable } }
    }
}


struct MachineAccessButtons: View {
    let reading: MachineStatus
    let fresh: Bool
    /// False where only the computer is shown (an agent's details); the terminal is in Technical details.
    var terminal = true
    @State private var error: String?
    private var screen: ScreenSharingSession { .shared }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if terminal, let url = reading.sshURL {
                    Button("Terminal", systemImage: "terminal") { open(url) }
                        .help(availability(reading.access?.ssh?.available, name: "SSH"))
                }
                if let request = reading.screenSharingConnection {
                    Button(screen.busy.contains(request) ? "Connecting…" : "Screen Sharing", systemImage: "display") {
                        Task { await screen.open(request) }
                    }
                    .disabled(screen.busy.contains(request))
                    .help("Open Screen Sharing through this server's SSH connection.")
                    .accessibilityIdentifier("screen-sharing-\(reading.agent)")
                    if screen.opened.contains(request) {
                        Button("Disconnect Screen Sharing", systemImage: "xmark.circle") {
                            Task { await screen.close(request) }
                        }.labelStyle(.iconOnly).disabled(screen.busy.contains(request))
                            .help("Close Founderizer's SSH connection for this screen.")
                    }
                } else if let url = reading.screenSharingURL {
                    Button("Screen Sharing", systemImage: "display") { open(url) }
                        .help(availability(reading.access?.screen_sharing?.available, name: String(l10n: "Screen Sharing")))
                }
            }.buttonStyle(.plain).font(FormMetrics.detail)
            if let error { Text(error).font(FormMetrics.detail).foregroundStyle(.orange) }
            if let request = reading.screenSharingConnection, let detail = screen.errors[request] {
                Text(detail).font(FormMetrics.detail).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func availability(_ value: Bool?, name: String) -> String {
        guard fresh, let value else { return String(l10n: "Open \(name) · Service status not confirmed") }
        return value ? String(l10n: "Open \(name) · Service on at last server check. Connection from this Mac is not checked.")
            : String(l10n: "Open \(name) · Service off at last server check. Connection from this Mac is not checked.")
    }
    private func open(_ url: URL) {
        error = NSWorkspace.shared.open(url) ? nil : url.scheme.map { String(l10n: "No app opened this connection. Check the default app for \($0.uppercased()) links.") }
            ?? String(l10n: "No app opened this connection. Check the default app for remote links.")
    }
}

struct TaskMachineAccess: View {
    @Bindable var store: FleetStore
    let agent: String
    /// **The server, from the machines' reading the store keeps** (`FleetStore.reading`), which the agent's panel and a
    /// server's page read too (T-06): its way in stands at the top of the task's panel from the first frame. A read of
    /// its own put it there when that read answered, over the rows that had shown first.
    private var reading: MachineStatus? { (store.reading("machines") as MachineList?)?.machines.first { $0.agent == agent } }
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let reading, reading.sshURL != nil || reading.screenSharingURL != nil {
                Text("Open server").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                MachineAccessButtons(reading: reading, fresh: store.isFresh && reading.isCurrent(at: Date().timeIntervalSince1970))
            }
            // Not while the window's notice says the outage (`FleetStore.hubNoticeShows`).
            if let error, !store.hubNoticeShows { Text(error).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted) }
        }.task(id: store.isFresh) {
            guard store.isFresh, let database = store.state?.db else { return }
            let hub = store.hub
            do {
                let result = try await HubClient().machines(hub: hub, database: database)
                guard !Task.isCancelled, store.hub == hub, store.state?.db == database else { return }
                store.keep(result, as: "machines"); error = nil
            } catch { if !Task.isCancelled { self.error = HubError.said(error) ?? String(l10n: "Server access is unavailable.") } }
        }
    }
}
