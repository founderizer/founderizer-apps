import AppKit
import FleetCore
import Observation
import SwiftUI

/// The last checklist this Mac read from one machine (PRODUCT.md 4.1), kept so that a machine's page shows its
/// checks again after the app is closed. It holds what `verify` answered and when — no credential, and nothing the
/// machine did not say itself.
struct MachineChecks {
    private static let key = "machineChecklists"

    private struct Kept: Codable {
        var checks: [VerifyCheck]
        var readAt: Double
    }

    static func remember(_ checklist: VerifyChecklist, machine: String, hub: URL) {
        var all = read()
        all[name(machine, hub: hub)] = Kept(checks: checklist.checks,
                                            readAt: checklist.readAt ?? Date().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func checklist(machine: String, hub: URL) -> VerifyChecklist? {
        guard let kept = read()[name(machine, hub: hub)] else { return nil }
        return VerifyChecklist(checks: kept.checks, readAt: kept.readAt)
    }

    /// A server renamed in Tailscale (`server_names`): its checks go with it, unless some are kept for the new name.
    static func move(_ machine: String, to new: String, hub: URL) {
        var all = read()
        guard let kept = all.removeValue(forKey: name(machine, hub: hub)), all[name(new, hub: hub)] == nil else { return }
        all[name(new, hub: hub)] = kept
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func read() -> [String: Kept] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Kept].self, from: data)) ?? [:]
    }

    private static func name(_ machine: String, hub: URL) -> String { "\(hub.absoluteString)|\(machine)" }
}

/// One machine's checks, on its own page: the state of each check, the one line it says, and the fix when there is
/// one. `READY` when nothing failed.
///
/// `verify` runs on the machine itself, so this Mac reads it over the owner's own SSH connection — the same
/// connection the install used, with the address, the user and the key it already remembers.
///
/// **It asks the owner for nothing the fleet already reports.** A machine this app has not installed takes its
/// address, its user and its port from the hub's own record of that machine (`MachineReach`), and the page shows
/// them as one line he can read and correct. The key his SSH agent should use is the only thing left that nothing
/// here can derive, and a machine with no `access` entry is said to have no connection on record — never a guess,
/// and never a password.
@MainActor @Observable
final class MachineChecksModel {
    let machine: String
    var host = ""
    var user = ""
    var port = "22"
    var identityFile: String?
    /// Which machine this is, which says where its checkout is and as whom `verify` runs there. The page derives
    /// it from the hub's own report — the hub's own machine, a Mac, or a Linux machine that joined — so nothing
    /// asks the owner a question about directory names.
    var kind: MachineCheckout
    private(set) var checklist: VerifyChecklist?
    private(set) var reading = false
    private(set) var failure: String?
    /// The step of a restart this Mac is driving now, in the owner's words, or nil.
    private(set) var restarting: String?
    /// When a restart this Mac drove last finished, so that a reading from before it offers no second restart.
    private(set) var restartedAt: Double?
    /// The step of an update of one helper that this Mac is driving now, in the owner's words, or nil.
    private(set) var updating: String?
    /// When an update this Mac drove last finished, so that a reading from before it offers no second update.
    private(set) var updatedAt: Double?
    /// What stopped the last update, in one line. It stays in the update's own row and out of the state row: the
    /// checks are still the last thing this Mac read of the machine, and the state row says those.
    private(set) var updateFailure: String?
    /// The owner is giving the connection himself, so the fields show in place of the line.
    var asksForTheMachine = false
    /// What the fleet last reported about reaching this machine, or nil while it has reported nothing.
    private(set) var fleetReach: MachineReach?
    /// The fleet reported this machine and had no SSH user for it. The page says that in those words instead of
    /// leaving the owner in front of empty boxes.
    private(set) var fleetHasNoConnection = false
    /// A closer look was asked for in this session, so what it found belongs on the face of the page. A look this
    /// app remembers from an earlier launch is a reading, and stays behind Details.
    private(set) var lookedNow = false
    /// A connection is settled: the owner gave it, a check already used it, or the fleet's own record was taken.
    /// A later reading never overwrites one of those.
    private var settled = false

    init(machine: String, hub: URL, kind: MachineCheckout) {
        self.machine = machine
        self.kind = kind
        checklist = MachineChecks.checklist(machine: machine, hub: hub)
        if let kept = InstallTargets.target(machine: machine, hub: hub) {
            host = kept.host; user = kept.user; port = String(kept.port); identityFile = kept.identityFile
            settled = true
        }
    }

    /// What the hub itself says about reaching this machine. It fills the connection this Mac will use, so the
    /// owner reads one line instead of filling four boxes, and it is taken once: a connection he gave himself, or
    /// one a check has already used, stands.
    /// `address` is the server's private address from the hub's list of servers, which also has a server that runs no
    /// agent yet and so has no reading.
    func fleetSays(_ reach: MachineReach?, address: String? = nil) {
        // A connection kept from an install names the public address that was typed, where the machine lets no SSH
        // in once its installer has run: it goes to the private address the fleet reports (`MachineReach.reaching`).
        if !asksForTheMachine { host = MachineReach(address: reach?.address ?? address).reaching(target).host }
        guard let reach else { return }
        fleetReach = reach
        fleetHasNoConnection = reach.onRecord == nil
        guard !settled, !asksForTheMachine, let known = reach.onRecord else { return }
        settled = true
        host = known.address; user = known.user; port = String(known.port)
    }

    /// Back to the fleet's own record, after the owner opened the fields and would rather not.
    func useTheFleetsConnection() {
        guard let known = fleetReach?.onRecord else { return }
        host = known.address; user = known.user; port = String(known.port)
        identityFile = nil
        asksForTheMachine = false
    }

    /// The one line that says how this Mac will reach the machine, or, where it cannot, what is missing.
    var connectionWords: String? {
        if target.isValid {
            return MachineReach.sentence(machine: machine, user: target.user, address: target.host,
                                         port: target.port, identityFile: identityFile)
        }
        return fleetHasNoConnection ? MachineReach.nothingOnRecord(machine) : nil
    }

    /// The owner needs a way to give another connection: the one he has does not work, or there is none to use.
    var offersAnotherConnection: Bool { !asksForTheMachine && (failure != nil || !target.isValid) }

    var target: InstallTarget {
        InstallTarget(host: host.trimmingCharacters(in: .whitespaces), user: user.trimmingCharacters(in: .whitespaces),
                      port: Int(port) ?? 0, identityFile: identityFile, becomeRoot: user != "root")
    }

    /// Runs `python3 fleet.py verify --json` on that machine and keeps what it answered.
    func check(hub: URL) {
        guard !reading, restarting == nil, updating == nil, target.isValid else {
            failure = target.problem
            return
        }
        reading = true; failure = nil
        run(InstallPlan.check(target: target, machine: kind), hub: hub) { [weak self] in self?.reading = false }
    }

    /// Restarts that machine over the same SSH connection, waits for it to come back, and reads its checks again.
    /// The owner sees each of those three steps while it goes on, and the fresh checklist when it is over.
    func restart(hub: URL) {
        guard !reading, restarting == nil, updating == nil, target.isValid else {
            failure = target.problem
            return
        }
        restarting = String(l10n: "Restarting \(machine)…"); failure = nil
        run(InstallPlan.restart(target: target, machine: kind), hub: hub) { [weak self] in
            self?.restarting = nil
            self?.restartedAt = Date().timeIntervalSince1970
        }
    }

    /// Updates one agent's helper on that machine over the same connection its checks come over: the checkout onto
    /// the configuration ref, that agent's own service, and the checks again. The hub refuses this for a helper it
    /// does not update itself — "the hub machine is maintained from the owner Mac" — and this Mac is what it names.
    ///
    /// It does not wait for the helper to be idle, because nothing outside that helper can hold its gate. So the
    /// row that calls this says what the restart of the service ends, and the owner decides.
    func update(agent: String, hub: URL) {
        guard !reading, restarting == nil, updating == nil, target.isValid else {
            failure = target.problem
            return
        }
        updating = String(l10n: "Updating Founderizer on \(agent.agentLabel)'s server…"); updateFailure = nil
        run(InstallPlan.update(target: target, machine: kind, agent: agent), hub: hub) { [weak self] in
            guard let self else { return }
            updating = nil
            // Only a successful update makes the hub's reading old news; a failed one keeps its row and its reason.
            if updateFailure == nil { updatedAt = Date().timeIntervalSince1970 }
        }
    }

    /// The line a restart or an update shows while it runs. A check reports nothing: it has one step, and the
    /// state says it.
    private func stepped(_ says: String) {
        if restarting != nil { restarting = says }
        if updating != nil { updating = says }
    }

    /// Where a plan's failure goes. An update's belongs in the update's own row, next to the button that tries it
    /// again: the state row must keep saying the checks, which are still the last thing this Mac read.
    private func problem(_ says: String) {
        if updating != nil { updateFailure = says } else { failure = says }
    }

    /// One plan over the owner's own connection: each step's line while it runs, then the checklist it ends with.
    /// A plan that failed leaves the last checklist alone, because what it said is still the last thing that was
    /// read; `failure` says what could not be done now.
    private func run(_ plan: InstallPlan, hub: URL, done: @MainActor @escaping () -> Void) {
        let machine = self.machine, target = plan.target
        let step: @Sendable (String) -> Void = { [weak self] says in Task { @MainActor in self?.stepped(says) } }
        Task { [weak self] in
            do {
                let answer = try await MachineInstaller(plan: plan, authKey: "").run { progress in
                    if progress.state == .running { step(progress.says) }
                }
                guard let self else { return }
                checklist = answer
                // A connection that really read this machine is settled, whoever gave it: no later reading of the
                // fleet's own record replaces a connection that works.
                asksForTheMachine = false
                settled = true
                lookedNow = true
                MachineChecks.remember(answer, machine: machine, hub: hub)
                InstallTargets.remember(target, machine: machine, hub: hub)
            } catch {
                guard let self else { return }
                problem((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            done()
        }
    }
}

/// **The face of a server's page**: one word about the machine, and a button only where he has something to do.
///
/// The owner's words, 20 October 2026: "I only care about connected or not connected, and if I need to do
/// something!" So the first row is `MachineConnection` — the hub's own live answer, which costs no SSH, no command
/// on his machine and no waiting — and under it only the rows he can act on: the restart the machine is waiting
/// for, the helper the hub will not update, and, after he has asked for a closer look himself, what it found.
///
/// **Nothing here connects to his machine on its own.** The closer look over his own SSH connection runs when he
/// presses for it and at no other time: it is the answer to "why not", not the way to learn "whether".
struct MachineStandingSection: View {
    @Bindable var store: FleetStore
    @Bindable var model: MachineChecksModel
    let server: ServerEntry
    /// The reading of each agent's machine, for the helpers here that the hub will not update and for the fleet's
    /// own record of how this machine is reached.
    var readings: [MachineStatus] = []
    /// The hub's own live answer about this machine: whether its helpers are reporting, and its own line where
    /// something is wrong.
    var connected: MachineConnection = .waiting
    /// The restart waits for one confirmation in the row, as Remove device does: no dialog, and the words say
    /// what it does to the agents on that machine.
    @State private var confirmingRestart = false
    /// The agent whose helper the owner is about to update, while its row asks for that one confirmation.
    @State private var confirmingUpdate: String?

    /// The helpers here the hub will not update, which are the only ones this page offers an update for.
    private var behind: [MachineStatus] {
        Self.behind(store: store, model: model, server: server, readings: readings)
    }

    private var standing: ServerStanding {
        Self.standing(store: store, model: model, server: server, readings: readings, connected: connected)
    }

    private static func behind(store: FleetStore, model: MachineChecksModel, server: ServerEntry,
                               readings: [MachineStatus]) -> [MachineStatus] {
        server.behindHelpers(readings, leads: store.state?.ui_features?.contains("leads") == true,
                             updatedAt: model.updatedAt)
    }

    /// The standing this card draws, from the same readings, so that the page can ask it too.
    static func standing(store: FleetStore, model: MachineChecksModel, server: ServerEntry, readings: [MachineStatus],
                         connected: MachineConnection) -> ServerStanding {
        ServerStanding.of(server, connected: connected, now: store.state?.time ?? Date().timeIntervalSince1970,
                          checklist: model.checklist, lookedNow: model.lookedNow, looking: model.reading,
                          restarting: model.restarting, restartedAt: model.restartedAt, failure: model.failure,
                          behind: behind(store: store, model: model, server: server, readings: readings).map(\.agent),
                          updating: model.updating)
    }

    /// **A machine that is well needs no card**: its page puts a tick beside its name instead (the owner, 27 October
    /// 2026: "instead of "Connected" a check icon would be enough"). Well is connected, with nothing going on and
    /// nothing to do: no restart, no helper to update, nothing a closer look found, no connection being asked for.
    static func isWell(_ standing: ServerStanding, model: MachineChecksModel) -> Bool {
        standing.settled && !standing.attention && !standing.working && !standing.needsRestart
            && !standing.needsUpdate && standing.failing.isEmpty && !model.asksForTheMachine
    }

    var body: some View {
        let standing = self.standing
        VStack(alignment: .leading, spacing: 14) {
            FormSection(footer: footer) {
                FormRow(standing.words, symbol: standing.symbol,
                        detail: standing.attention ? nil : standing.says,
                        warning: standing.attention ? [standing.says, standing.fix]
                            .compactMap { $0 }.joined(separator: "\n") : nil) {
                    buttons(standing)
                }.accessibilityIdentifier("machine-standing")
                if standing.needsRestart { restartRow }
                // The helper the hub will not take, with the one row that puts it right. It is on the face and not
                // behind Details because the state row names the problem, and the owner's rule for this page is
                // that a state which says something is wrong carries the way to put it right.
                ForEach(behind) { reading in updateRow(reading.agent) }
                // What the closer look he asked for found. Each one is a mark and not a sentence: the line that
                // look wrote, and the command it named, are behind the mark, where the app keeps them.
                ForEach(standing.failing) { check in
                    MachineLookRow(check: check, machine: model.machine)
                }
            }
            if model.asksForTheMachine { MachineConnectionFields(model: model) }
        }
        // What the hub itself reports about reaching this machine. It arrives after the page draws, and again
        // whenever the readings change, so the connection is filled from the fleet's own record and the owner is
        // asked for none of it.
        .task(id: MachineReach.of(model.machine, in: readings)) {
            model.fleetSays(MachineReach.of(model.machine, in: readings), address: server.address)
        }
    }

    /// **A machine that is connected gets no button**, which is the whole of what the owner asked for. One that is
    /// not gets the one thing that answers "why not": a closer look over his own connection, which reaches the
    /// machine by a different road than its helper and so can tell a stopped helper from a machine that is down.
    @ViewBuilder private func buttons(_ standing: ServerStanding) -> some View {
        if standing.working {
            ProgressView().controlSize(.small)
        } else if !standing.settled {
            HStack(spacing: 8) {
                if model.offersAnotherConnection {
                    Button("Use a different connection") { model.asksForTheMachine = true }
                        .buttonStyle(FleetOutlineButtonStyle()).accessibilityIdentifier("machine-check-connection")
                }
                if !connected.isConnected {
                    Button("Find out why") { model.check(hub: store.hub) }
                        .buttonStyle(FleetPrimaryButtonStyle()).disabled(!model.target.isValid)
                        .accessibilityIdentifier("machine-check-now")
                }
            }
        }
    }

    /// The restart, which the owner asked for and which no other screen offers: this Mac restarts the machine over
    /// its own connection, then waits for it and looks at it again.
    @ViewBuilder private var restartRow: some View {
        if confirmingRestart {
            FormRow("Restart \(model.machine)?", symbol: "exclamationmark.triangle",
                    warning: String(l10n: "Its agents stop while it is away, and any task running on it ends. Founderizer waits for the server and looks at it again.")) {
                HStack(spacing: 8) {
                    Button("Cancel") { confirmingRestart = false }.buttonStyle(FleetOutlineButtonStyle())
                        .accessibilityIdentifier("machine-restart-cancel")
                    Button("Restart now") { confirmingRestart = false; model.restart(hub: store.hub) }
                        .buttonStyle(FleetDangerButtonStyle()).disabled(!model.target.isValid)
                        .accessibilityIdentifier("machine-restart-confirm")
                }
            }
        } else {
            // What a restart costs is the confirmation's to say. This row says what it is and why.
            FormRow("Restart this server", symbol: "arrow.clockwise.circle",
                    detail: model.target.isValid ? ServerStanding.restartSays(server.reading?.security?.pending_security)
                        : String(l10n: "Founderizer has no connection to this server yet.")) {
                Button("Restart") { confirmingRestart = true }.buttonStyle(FleetOutlineButtonStyle())
                    .disabled(model.reading || model.restarting != nil || model.updating != nil || !model.target.isValid)
                    .accessibilityIdentifier("machine-restart")
            }
        }
    }

    /// The update of one helper, which no other screen offers for a machine the hub refuses: this Mac moves that
    /// agent's checkout onto the configuration ref, restarts its service and looks at the machine again.
    ///
    /// The hub's own update waits for a helper to be idle; this one cannot, because the gate that holds a session
    /// back lives inside that helper. So the confirmation says what the restart of the service ends, and names the
    /// work when the hub's own state says that agent is working now. The owner decides, which is the only honest
    /// answer a page driven from outside the machine has.
    @ViewBuilder private func updateRow(_ agent: String) -> some View {
        if confirmingUpdate == agent {
            FormRow("Update Founderizer on \(agent.agentLabel)'s server?", symbol: "exclamationmark.triangle",
                    warning: updateCosts(agent)) {
                HStack(spacing: 8) {
                    Button("Cancel") { confirmingUpdate = nil }.buttonStyle(FleetOutlineButtonStyle())
                        .accessibilityIdentifier("machine-update-cancel")
                    Button("Update now") { confirmingUpdate = nil; model.update(agent: agent, hub: store.hub) }
                        .buttonStyle(FleetDangerButtonStyle()).disabled(!model.target.isValid)
                        .accessibilityIdentifier("machine-update-confirm")
                }
            }
        } else {
            FormRow("Update Founderizer on \(agent.agentLabel)'s server", symbol: "arrow.down.circle",
                    detail: model.target.isValid ? ServerStanding.updateSays([agent])
                        : String(l10n: "Founderizer has no connection to this server yet."),
                    warning: model.updateFailure) {
                Button("Update") { confirmingUpdate = agent }.buttonStyle(FleetOutlineButtonStyle())
                    .disabled(model.reading || model.restarting != nil || model.updating != nil || !model.target.isValid)
                    .accessibilityIdentifier("machine-update-\(agent)")
            }
        }
    }

    /// What this update ends, in the owner's own terms, and the work it ends by name when the hub says there is any.
    private func updateCosts(_ agent: String) -> String {
        let working = store.state?.working(agent) ?? []
        guard !working.isEmpty else {
            return String(l10n: "Its service restarts, so anything \(agent.agentLabel) starts meanwhile is lost. The hub's own update waits until \(agent.agentLabel) is idle; this one cannot. Founderizer looks at the server again afterwards.")
        }
        if working.count == 1 {
            return String(l10n: "Its service restarts, so “\(working[0].title)”, which \(agent.agentLabel) is working on now, ends. The hub's own update waits until \(agent.agentLabel) is idle; this one cannot. Founderizer looks at the server again afterwards.")
        }
        return String(l10n: "Its service restarts, so the \(working.count) tasks \(agent.agentLabel) is working on now end. The hub's own update waits until \(agent.agentLabel) is idle; this one cannot. Founderizer looks at the server again afterwards.")
    }

    /// The card says nothing under it while the machine is simply connected. Where this Mac could not reach it,
    /// the connection it tried is the next thing to know, and the fields are one button away.
    private var footer: String? {
        model.offersAnotherConnection ? model.connectionWords : nil
    }
}

extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}

/// **One thing a closer look found, as a mark.** The sentence that look wrote and the command it named are
/// behind the mark, which is where the app keeps what it knows without spending his attention on it.
///
/// A cross carries what to do about it. The sign-in is his own step and its card is on this page, so that cross
/// says so. For everything else the command `verify` names is work on the machine and not his to type, and the
/// app already has the one route that does something with it: Report a problem carries every failed check, with
/// the line it wrote, to one of his own agents. **Founderizer does not offer to run that command itself**: it is
/// a string the machine sent, and a button that ran it would be this Mac doing whatever a machine asked for.
struct MachineLookRow: View {
    let check: VerifyCheck
    let machine: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        FormMarkRow(title: check.title, state: MarkState.of(check), words: words, detail: detail,
                    act: act, whoActs: whoActs, identifier: "look-\(check.check)")
    }

    private var words: String {
        check.passed ? String(l10n: "Fine") : check.warned ? String(l10n: "Worth knowing") : String(l10n: "Not fine")
    }

    private var detail: String {
        [check.says, check.passed ? nil : check.fix].compactMap { $0 }.joined(separator: "\n\n")
    }

    private var act: (words: String, run: () -> Void)? {
        guard check.failed, check.check != VerifyChecklist.signInCheck else { return nil }
        return (String(l10n: "Report a problem"), { openWindow(id: FounderizerApp.reportWindow) })
    }

    private var whoActs: String? {
        guard check.failed, check.check == VerifyChecklist.signInCheck else { return nil }
        return String(l10n: "Signing in is your own step, and its card is on this page.")
    }
}

/// **The connection the owner gives himself**, when the fleet's own record is wrong or there is none. It shows
/// only then: everything in it that the hub reports — the address, the user and the port — is already filled from
/// the hub's own record, and the card above says it in one line.
///
/// It asks for three things and no fourth. It does not ask **which machine** this is: the hub names each machine
/// and reports its system, so the page derives that (`ServersPage.checkout`). It asks for a key only because
/// nothing can derive which of the owner's keys opens a machine, and the one his SSH agent holds is the answer
/// until a connection fails.
struct MachineConnectionFields: View {
    @Bindable var model: MachineChecksModel

    var body: some View {
        FormSection("How this Mac reaches \(model.machine)",
                    footer: String(l10n: "The key is read by `ssh` on this Mac and never leaves it. Founderizer remembers the address, the user and the key — never a password.")) {
            FormRow("Address", symbol: "network") {
                TextField("", text: $model.host).fleetField().frame(width: 200)
                    .accessibilityIdentifier("machine-check-host")
            }
            FormRow("User", symbol: "person", detail: String(l10n: "The user you reach that server with over SSH.")) {
                HStack(spacing: 8) {
                    TextField("", text: $model.user).fleetField().frame(width: 110)
                        .accessibilityIdentifier("machine-check-user")
                    TextField(text: $model.port, prompt: Text(verbatim: "")) { Text("22") }
                        .fieldPlaceholder("22", shows: model.port.isEmpty).fleetField().frame(width: 60)
                        .accessibilityIdentifier("machine-check-port")
                }
            }
            FormRow("SSH key", symbol: "key", detail: model.identityFile ?? String(l10n: "The keys your SSH agent holds.")) {
                Button(model.identityFile == nil ? "Choose key" : "Change") { chooseKey() }
                    .buttonStyle(FleetOutlineButtonStyle()).accessibilityIdentifier("machine-check-key")
            }
        } accessory: {
            // The way back out, so that opening these fields is never a dead end.
            if model.fleetReach?.onRecord != nil {
                Button("Use the fleet's connection") { model.useTheFleetsConnection() }
                    .buttonStyle(FleetOutlineButtonStyle())
                    .accessibilityIdentifier("machine-check-fleet-connection")
            }
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = String(l10n: "Choose the SSH private key for \(model.machine)")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = InstallTarget.keyFolder
        if panel.runModal() == .OK { model.identityFile = panel.url?.path }
    }
}
