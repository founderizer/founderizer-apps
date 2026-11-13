import AppKit
import FleetCore
import Observation
import SwiftUI

/// What this Mac remembers about a machine it installed: where it is and how to reach it over SSH. No secret is in
/// here — the key is a path that `ssh` reads, and the Tailscale key is never kept at all — so a later check of that
/// machine needs no typing again.
struct InstallTargets {
    private static let key = "machineInstallTargets"

    private struct Kept: Codable {
        var host: String
        var user: String
        var port: Int
        var identityFile: String?
    }

    static func remember(_ target: InstallTarget, machine: String, hub: URL) {
        var all = read()
        all[name(machine, hub: hub)] = Kept(host: target.host, user: target.user, port: target.port,
                                            identityFile: target.identityFile)
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func target(machine: String, hub: URL) -> InstallTarget? {
        guard let kept = read()[name(machine, hub: hub)] else { return nil }
        let target = InstallTarget(host: kept.host, user: kept.user, port: kept.port, identityFile: kept.identityFile)
        return target.isValid ? target : nil
    }

    /// The address kept for each machine of this hub, by its name: what a renamed server is recognized by.
    static func hosts(hub: URL) -> [String: String] {
        let prefix = name("", hub: hub)
        return Dictionary(read().compactMap { key, kept in
            key.hasPrefix(prefix) ? (String(key.dropFirst(prefix.count)), kept.host) : nil
        }) { first, _ in first }
    }

    /// The key files of this hub's kept root connections, each once: the keys that this Mac already uses for root,
    /// which the door round offers a business server that has no kept connection (`DoorAccess.LoginKeys`).
    static func rootKeys(hub: URL) -> [String] {
        let prefix = name("", hub: hub)
        return Set(read().compactMap { key, kept in
            key.hasPrefix(prefix) && kept.user == "root" ? kept.identityFile : nil
        }).sorted()
    }

    /// A server renamed in Tailscale (`server_names`): its connection goes with it, unless one is kept for the new name.
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

/// Tailscale would not give this Mac a key for this machine, with its own words for why. It is its own error
/// because its answer is a screen and not a line: the install asks the private-network question again, where the
/// credential can be replaced.
struct NetworkKeyRefused: LocalizedError, Equatable, Sendable {
    let says: String
    init(_ says: String) { self.says = says }
    var errorDescription: String? { says }
}

/// One install of one machine, from the form to the checklist (PRODUCT.md P3).
///
/// It lives in the store while other pages show, as a provider setup does, so an install that takes ten minutes is
/// not lost by a click. The Tailscale key is in this model's memory and nowhere else: it is cleared as soon as the
/// install ends, and it is in no line that this app keeps or shows.
@MainActor @Observable
final class MachineInstallModel {
    /// The two ways of adding a machine, and the line a customer can still paste themselves.
    enum Way: String, CaseIterable, Identifiable, Hashable {
        case linux, mac, line
        var id: String { rawValue }
        var title: String {
            switch self {
            // Three words at most, as a card of a choice has them (the owner, 3 November 2026: "too much text").
            case .linux: "Linux server"
            case .mac: "Mac"
            case .line: "Paste a line"
            }
        }
    }

    var way: Way = .linux
    /// The name the owner gives this machine, on a hub from before `server_names`. A hub with it names the machine by
    /// its name in Tailscale, and this is then only the name a Mac's installer is sent (`MacInstallOrder`).
    var name = ""
    /// The name the fleet knows the machine by once it joined: on a hub with `server_names` the name the hub gave it at
    /// its join, read from the hub's join state; else the name typed. Nil until it is known.
    private(set) var server: String?
    /// This install's join code as the hub wrote it, which finds its join among the hub's without a name.
    private var made: (name: String, kind: String, expiresAt: Double)?
    /// The first agent of a Mac that this install named: the hub adds it, so the page offers no Add agent.
    private(set) var firstAgent: String?
    /// The AI that the owner chose for this server, nil on a hub that takes no choice.
    var ai: ServerAI?
    var host = ""
    var user = "root"
    var port = "22"
    var identityFile: String?
    /// The key for a machine that is not on the owner's private network yet, as this Mac minted it from the
    /// credential in its keychain (`PrivateNetwork`). Memory only, for the length of one install, and in the
    /// install's redaction list so no line can hold it. Nobody types it: a fleet whose network is connected never
    /// sees a key, and a machine that signs in by Tailscale's own link needs none (`NetworkSignIn`).
    private(set) var authKey = ""
    /// The password of a `sudo` that asks for one (`PasswordOnce`), for this install's root steps only: the installer
    /// clears it when it ends, and this lets go of it then.
    var sudoPassword: PasswordOnce.Password?
    /// A new hub only: the address of the Founderizer repository. It has one answer, which is filled in.
    var source = InstallPlan.defaultSource
    /// The Mac way: where that Mac's installer waits, and the link code it shows.
    var macHost = ""
    var linkCode = ""

    private(set) var steps: [InstallProgress] = []
    /// The ids of the running plan's steps, in order: the installer reports a step only when it starts, and the minutes
    /// left count the steps it has not reached yet from this (`InstallPhases`).
    private(set) var planned: [String] = []
    /// The step that runs now and when it began, for the minutes that go down within a long step (`InstallPhases`).
    private(set) var runningStep: String?
    private(set) var runningSince = Date()
    /// The Tailscale link this install waits on, while it waits: the lines of the step that is running.
    var networkSignIn: NetworkSignIn? {
        steps.last(where: { $0.state == .running }).flatMap { NetworkSignIn.found(in: $0.lines) }
    }
    private(set) var running = false
    private(set) var checklist: VerifyChecklist?
    private(set) var failure: String?
    /// The words the install stopped with, as the machine or `ssh` said them: the stop's line keeps them on its hover,
    /// and says `failure`, a few plain words of this app (`InstallError.plain`).
    private(set) var failureDetail: String?
    /// The install stopped only because this machine could not get onto the owner's private network by itself and
    /// no Tailscale key was given. Then the key is the one question left, and the screen asks it in the owner's own
    /// words.
    private(set) var needsNetworkKey = false
    /// What Tailscale said when this Mac tried to mint the key from the credential it holds. A credential that was
    /// ended or that expired leads to the same one question, and this is the line that says why it is being asked
    /// of a fleet that already answered it once.
    private(set) var networkFailure: String?
    /// The address this Mac claimed, after a hub install: the app connects to it by itself.
    private(set) var hubAddress: String?
    private var work: Task<Void, Never>?

    var target: InstallTarget {
        InstallTarget(host: host.trimmingCharacters(in: .whitespaces), user: user.trimmingCharacters(in: .whitespaces),
                      port: Int(port) ?? 0, identityFile: identityFile, becomeRoot: user != "root")
    }

    /// Why Install cannot go now, or nil. A typed name is checked against the names the fleet already has.
    func problem(taken: [String], firstMachine: Bool, typedName: Bool) -> String? {
        if firstMachine {
            guard let repository = URL(string: source.trimmingCharacters(in: .whitespaces)),
                  ["https", "ssh", "git"].contains(repository.scheme ?? ""), repository.host != nil else {
                return String(l10n: "Give the address of the Founderizer repository, from your own download page.")
            }
        } else if typedName, let trouble = Servers.nameProblem(name, taken: taken) {
            return trouble
        }
        return target.problem
    }

    /// The key this machine needs, or nil when this Mac holds no credential: the machine is on the private network
    /// already, or it signs in by Tailscale's own link. One key for one machine, used once and worthless in fifteen minutes
    /// (`NetworkClient.key`). A credential Tailscale refuses stops the install with Tailscale's own words, instead
    /// of installing a machine that cannot be reached.
    private func mintKey(for machine: String, life: Int = PrivateNetwork.keyLifeSeconds,
                         tags: [String] = [PrivateNetwork.tag]) async throws {
        // **The fleet's own key first** (the onboarding of 4 November 2026): made once from one pasted access token
        // (`TailscaleFleetKey`), it makes each server's join key, tagged and pre-approved, so no server waits for a
        // press and none expires. The credential of before stays the way for a fleet that has only it.
        let fleetKey = TailscaleFleetKey()
        if fleetKey.isHeld {
            do { authKey = try await fleetKey.mintAuthKey(hostname: machine); return }
            catch { throw NetworkKeyRefused((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
        }
        guard let credential = NetworkCredentialStore.read() else { authKey = ""; return }
        do { authKey = try await NetworkClient().key(for: machine, with: credential, life: life, tags: tags) }
        catch {
            // A credential Tailscale no longer accepts asks the same question as a machine that is not on the
            // network, so it reaches the same screen instead of ending as one more line of a failed install.
            throw NetworkKeyRefused((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Installs the hub itself: the first machine of a fleet, which has no hub to ask for a line. The claim at its
    /// end proves this Mac's own address to that hub, and the app then connects to it.
    func installHub(store: FleetStore) {
        guard !running else { return }
        work?.cancel()      // the reading of a Mac's order before this one
        running = true; failure = nil; failureDetail = nil; needsNetworkKey = false; networkFailure = nil; steps = []; planned = []; checklist = nil
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await mintKey(for: "hub")
                let plan = InstallPlan.hub(target: target, source: source.trimmingCharacters(in: .whitespaces),
                                           authKey: authKey.isEmpty ? nil : authKey)
                try await run(plan: plan, store: store, machine: "hub")
            } catch {
                finish(error: error)
            }
        }
    }

    /// Joins a machine to the hub this app is connected to: the hub gives the one-time line, and this Mac runs it
    /// over the owner's own connection.
    func installMachine(store: FleetStore) {
        guard !running, let database = store.state?.db else { return }
        // A hub with `server_names` names the server by its name in Tailscale at its join, so it is sent no name.
        let machine = Servers.asksName(store.state?.ui_features) ? name : nil
        work?.cancel()      // the reading of a Mac's order before this one
        running = true; failure = nil; failureDetail = nil; needsNetworkKey = false; networkFailure = nil; steps = []; planned = []; checklist = nil
        server = machine; made = nil
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let join = try await HubClient().joinCode(hub: store.hub, database: database,
                                                          client: store.installation, name: machine, kind: "linux")
                made = (join.name, join.kind, join.expires_at)
                guard let line = join.line, let code = join.code else {
                    throw InstallError.cannotStart(String(l10n: "The hub gave no join line. Try again."))
                }
                // The key carries the tags of the hub's own join line, as the sign-in link does, so the server has
                // the tags by which the tailnet's policy gives the fleet's machines their rights. A credential that
                // may not give those tags leaves the server to the link, which the owner approves.
                let tags = NetworkSignIn.tags(inLine: line)
                do { try await mintKey(for: machine ?? target.host, tags: tags.isEmpty ? [PrivateNetwork.tag] : tags) }
                catch is NetworkKeyRefused where !tags.isEmpty { authKey = "" }
                let plan = InstallPlan.join(target: target, line: line, code: code,
                                            authKey: authKey.isEmpty ? nil : authKey)
                try await run(plan: plan, store: store, machine: machine)
            } catch {
                finish(error: error)
            }
        }
    }

    /// Links **a Mac that stays on**: the hub's one-time line goes to the installer that runs there, with the link
    /// code the owner read off its screen. The app then reads that installer until the install ends. `withAgent`
    /// false: the order names no first agent, because the Mac is the server of an agent that the fleet has already (the
    /// manager of a new fleet, which the hub refuses as a Mac's new agent).
    func linkMac(store: FleetStore, withAgent: Bool = true) {
        guard !running, let database = store.state?.db else { return }
        guard let installer = MacInstallerClient.address(macHost), let code = ClaimCode.read(linkCode) else {
            failure = MacLinkError.notAnAddress.errorDescription; failureDetail = nil
            return
        }
        guard Servers.setsUpMacs(store.state?.ui_features) else {
            failure = String(l10n: "Your hub needs the newest Founderizer first: Settings, Updates."); failureDetail = nil
            return
        }
        // A hub with `server_names` names this Mac by its name in Tailscale at its join, so its code is made with no
        // name. The installer is still sent a name the hub allows: its older copies refuse an order without one.
        let asks = Servers.asksName(store.state?.ui_features)
        let machine = asks || Servers.nameProblem(name, taken: []) == nil ? name : Servers.suggestedName(taken: [])
        // The first agent of this Mac: the name Add agent would suggest. The hub adds it once this Mac has joined.
        firstAgent = withAgent ? AddAgentModel.freeName(taken: Set(store.state?.agents.map(\.name) ?? [])) : nil
        work?.cancel()      // the reading of the order before this one
        running = true; failure = nil; failureDetail = nil; steps = []; planned = []; checklist = nil
        server = asks ? machine : nil; made = nil
        work = Task { [weak self] in
            guard let self else { return }
            do {
                // An installer from before the choice would wait for a sign-in that this Mac does not have.
                if let ai, ai != .both, try await MacInstallerClient().state(code: code, from: installer).choice != true {
                    throw InstallError.cannotStart(String(l10n: "The installer on that Mac is out of date. Download it again."))
                }
                let join = try await HubClient().joinCode(hub: store.hub, database: database, client: store.installation,
                                                          name: asks ? machine : nil, kind: "mac", agent: firstAgent, ai: ai)
                made = (join.name, join.kind, join.expires_at)
                guard let line = join.line else {
                    throw InstallError.cannotStart(String(l10n: "The hub gave no join line. Try again."))
                }
                try await mintKey(for: asks ? machine : installer.host ?? "", life: PrivateNetwork.macKeyLifeSeconds)
                let order = MacInstallOrder(code: code, hub: store.hub.absoluteString, name: machine, line: line,
                                            authKey: authKey.isEmpty ? nil : authKey, agent: firstAgent)
                let client = MacInstallerClient()
                record(try await client.send(order, to: installer))
                authKey = ""
                var unread = 0
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(3))
                    let state: MacInstallState
                    do { state = try await client.state(code: code, from: installer); unread = 0 }
                    // After a stop that Mac's installer may have started again with a new code, and three reads with
                    // this one would close it to orders. The stop stays on the screen.
                    catch MacLinkError.refused(_) where failure != nil { return }
                    catch is MacLinkError where unread < MacInstallerClient.unreadTries {
                        unread += 1     // a refusal comes in the clear, so it may be a stranger's: only a count ends this
                        continue
                    }
                    catch is MacLinkError where failure != nil { return }
                    try Task.checkCancellation()
                    record(state)
                    // A stop is not the end: a Try again at that Mac goes on from it, and this screen goes with it.
                    if state.failed {
                        if failure == nil { finish(error: MacLinkError.refused(state.says)) }
                        continue
                    }
                    if failure != nil {
                        running = true; failure = nil; failureDetail = nil; needsNetworkKey = false; networkFailure = nil
                    }
                    if state.isDone {
                        let named = asks ? machine : await joinedName(store: store)
                        server = named
                        checklist = state.checklist
                        running = false
                        if let answer = state.checklist, let named {
                            MachineChecks.remember(answer, machine: named, hub: store.hub)
                        }
                        return
                    }
                }
            } catch {
                if !Task.isCancelled { finish(error: error) }
            }
        }
    }

    /// The installer's own steps, in the same rows as an install this Mac drives itself.
    private func record(_ state: MacInstallState) {
        for step in state.steps {
            record(InstallProgress(step: step.step, title: step.title, says: step.says,
                                   state: step.state == "done" ? .done : step.state == "failed" ? .failed : .running,
                                   detail: step.state == "failed" ? step.says : nil))
        }
        if state.steps.isEmpty {
            record(InstallProgress(step: "order", title: String(l10n: "The order"), says: state.says, state: .running))
        }
    }

    /// `machine` nil: the hub names the server at its join (`server_names`), and the install reads that name before it
    /// keeps the connection and the checks under it.
    private func run(plan: InstallPlan, store: FleetStore, machine: String?) async throws {
        planned = plan.steps.map(\.id)
        let installer = MachineInstaller(plan: plan, authKey: authKey, sudoPassword: sudoPassword)
        defer { sudoPassword = nil }
        let answer: VerifyChecklist
        do {
            answer = try await installer.run { progress in
                Task { @MainActor [weak self] in self?.record(progress) }
            }
        } catch {
            // Once on the private network the machine lets SSH in there only: a Try again goes to that address.
            host = await installer.reached.host
            throw error
        }
        authKey = ""
        let reached = await installer.reached
        host = reached.host
        var machine = machine
        if machine == nil { machine = await joinedName(store: store) }
        server = machine
        checklist = answer
        running = false
        guard let machine else { return }
        InstallTargets.remember(reached, machine: machine, hub: store.hub)
        MachineChecks.remember(answer, machine: machine, hub: store.hub)
        if plan.job == .hub, let claimed = claimedAddress() {
            hubAddress = claimed
            store.addressText = claimed
            // The first run reads its install by the store's hub address, which the connection below moves.
            store.keepInstall(self, at: claimed)
            await store.connect()
            // Both are kept under the hub's address, and a hub install has none until the claim above gives it
            // one: the two lines before this wrote them under the address this Mac had before. So keep them again
            // under the address the app now uses, or that machine's own page would ask for an address, a user and
            // a key that this very install already used.
            InstallTargets.remember(reached, machine: machine, hub: store.hub)
            MachineChecks.remember(answer, machine: machine, hub: store.hub)
        }
    }

    /// The name the hub gave the server that joined with this install's code (`server_names`): its join state has it
    /// from the join's commit, which the install's last step comes after. Up to five reads, three seconds apart, for a
    /// hub that is slow to answer; nil after them.
    private func joinedName(store: FleetStore) async -> String? {
        guard let made, let database = store.state?.db else { return nil }
        for read in 0..<5 {
            if read > 0 { try? await Task.sleep(for: .seconds(3)) }
            guard !Task.isCancelled else { return nil }
            if let join = (try? await HubClient().servers(hub: store.hub, database: database))?.join,
               join.isOf(name: made.name, kind: made.kind, expiresAt: made.expiresAt), join.state == "joined",
               let server = join.server { return server }
        }
        return nil
    }

    /// The hub's own address, out of the claim step this install already made.
    private func claimedAddress() -> String? {
        for step in steps.reversed() where step.step == "claim" {
            for line in step.lines {
                guard let found = line.range(of: "[0-9]{1,3}(\\.[0-9]{1,3}){3}", options: .regularExpression),
                      ClaimCode.isPrivateAddress(String(line[found])) else { continue }
                return "http://\(line[found]):8765"
            }
        }
        return nil
    }

    private func record(_ progress: InstallProgress) {
        if let at = steps.firstIndex(where: { $0.step == progress.step }) { steps[at] = progress } else { steps.append(progress) }
        let now = steps.first(where: { $0.state == .running })?.step
        if now != runningStep { runningStep = now; runningSince = Date() }
    }

    private func finish(error: Error) {
        let says = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        failure = (error as? InstallError)?.plain(host: target.host) ?? says
        failureDetail = says
        if let refused = error as? NetworkKeyRefused {
            needsNetworkKey = true
            networkFailure = refused.says
        } else {
            needsNetworkKey = InstallPlan.needsNetworkKey(says) && authKey.isEmpty
            networkFailure = nil
        }
        running = false
        authKey = ""
    }

    func cancel() {
        work?.cancel(); work = nil
        running = false
        authKey = ""
    }

    /// Takes a server that a check proved, or that a provider made: its address, user, port and key, and the password
    /// of its `sudo` when that asks for one.
    func use(_ target: InstallTarget, sudo: PasswordOnce.Password? = nil) {
        host = target.host; user = target.user; port = String(target.port); identityFile = target.identityFile
        sudoPassword = sudo
    }

    func again() {
        guard !running else { return }
        work?.cancel(); work = nil
        steps = []; planned = []; checklist = nil; failure = nil; failureDetail = nil; hubAddress = nil; needsNetworkKey = false; networkFailure = nil
        server = nil; made = nil
    }
}

/// The form of a machine installed from this Mac: the address, the user and the key the owner already uses, and
/// nothing else. The Founderizer repository has one answer, so it is filled in and folded into Advanced; the
/// Tailscale key is not asked for here at all, because the install asks for it only if the machine turns out not
/// to be on the owner's private network.
struct MachineInstallForm: View {
    @Bindable var model: MachineInstallModel
    @State private var advanced = false
    let taken: [String]
    /// The hub itself, which has no hub to ask for a line.
    let firstMachine: Bool
    let install: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            FormSection {
                if !firstMachine {
                    FormRow("Name", symbol: "character.cursor.ibeam",
                            warning: model.name.isEmpty ? nil : Servers.nameProblem(model.name, taken: taken)) {
                        TextField(text: $model.name, prompt: Text(verbatim: "")) { Text("Server name") }
                            .fieldPlaceholder(String(l10n: "Server name"), shows: model.name.isEmpty)
                            .fleetField()
                            .frame(width: 240).accessibilityIdentifier("install-name")
                    }
                }
                // No line under the address, and none under the key's row (D-2): the row says it.
                FormRow("Address", symbol: "network") {
                    TextField(text: $model.host, prompt: Text(verbatim: "")) { Text("203.0.113.9") }
                        .fieldPlaceholder("203.0.113.9", shows: model.host.isEmpty)
                        .fleetField()
                        .frame(width: 240).accessibilityIdentifier("install-host")
                }
                FormRow("User", symbol: "person", detail: model.user == "root" ? nil : String(l10n: "Not root: it needs sudo.")) {
                    HStack(spacing: 8) {
                        TextField(text: $model.user, prompt: Text(verbatim: "")) { Text("root") }
                            .fieldPlaceholder("root", shows: model.user.isEmpty)
                            .fleetField()
                            .frame(width: 130).accessibilityIdentifier("install-user")
                        TextField(text: $model.port, prompt: Text(verbatim: "")) { Text("22") }
                            .fieldPlaceholder("22", shows: model.port.isEmpty)
                            .fleetField()
                            .frame(width: 70).accessibilityIdentifier("install-port")
                    }
                }
                FormRow("SSH key", symbol: "key", detail: model.identityFile) {
                    HStack(spacing: 8) {
                        if model.identityFile != nil {
                            Button("Use the agent") { model.identityFile = nil }.buttonStyle(FleetOutlineButtonStyle())
                        }
                        Button(model.identityFile == nil ? "Choose key" : "Change") { chooseKey() }
                            .buttonStyle(FleetOutlineButtonStyle()).accessibilityIdentifier("install-key")
                    }
                }
                // The question a careful person asks before handing over a key, answered in its own row and not in
                // the small print under it.
                FormRow("Your key never leaves this Mac", symbol: "lock.shield")
            }
            if firstMachine {
                AdvancedLink(open: $advanced).accessibilityIdentifier("install-advanced")
                if advanced {
                    FormSection(footer: String(l10n: "Your download page gives this address.")) {
                        FormRow("Repository", symbol: "shippingbox") {
                            TextField(text: $model.source, prompt: Text(verbatim: "")) { Text(InstallPlan.defaultSource) }
                                .fieldPlaceholder(InstallPlan.defaultSource, shows: model.source.isEmpty)
                                .fleetField()
                                .frame(width: 320).accessibilityIdentifier("install-source")
                        }
                    }
                }
            }
            if let problem = model.problem(taken: taken, firstMachine: firstMachine, typedName: !firstMachine),
               !model.host.isEmpty {
                Text(problem).font(SetupMetrics.textFont).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Only once the form holds what an install needs: no grey button (the owner: "dont show the send button
            // if it's not clickable"). It stands in the middle, under the form, as every setup step's action does.
            if !model.running && model.problem(taken: taken, firstMachine: firstMachine, typedName: !firstMachine) == nil {
                Button(firstMachine ? "Install the hub" : "Install server") { install() }
                    .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("install-start")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = String(l10n: "Choose the SSH private key for this server")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = InstallTarget.keyFolder
        if panel.runModal() == .OK { model.identityFile = panel.url?.path }
    }
}

/// An install while it runs and when it ends: one row for each step, then the machine's own checklist.
/// **"› Advanced", centred under a setup step's form, where Back is, and in the step's 15 pt** (item 45, fix round 2): a
/// disclosure put its arrow and its 12-pt word at the form's left edge, in a step whose words are centred. What it opens
/// stands under it.
struct AdvancedLink: View {
    @Binding var open: Bool

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(IconMetrics.symbol(11, weight: .semibold))
                Text("Advanced")
            }.padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.vertical, -IconMetrics.reach)
        .font(SetupMetrics.textFont).foregroundStyle(FleetStyle.muted)
        .frame(maxWidth: .infinity)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }
}

struct MachineInstallRun: View {
    @Bindable var model: MachineInstallModel
    /// The private network, for the one question a stopped install can leave.
    @State private var network = PrivateNetworkModel()
    let title: String
    /// What the owner does next, when the install reached its end.
    let next: AnyView
    /// Starts the same install again, which is what the one question of this screen leads to.
    var again: (() -> Void)?
    /// The line of what runs now under the title: the first run's "Building your fleet" only, which the owner approved
    /// on 5 November 2026.
    var showsStatus = false

    var body: some View {
        if model.needsNetworkKey, let again { network(again) }
        else if let signIn = model.networkSignIn { approve(signIn) }
        else { run }
    }

    /// The one question that is asked only when the machine turns out not to be on the owner's private network and
    /// cannot get there by Tailscale's own link: connect the network, once. After that this Mac makes the key for every
    /// machine itself, so this screen is seen once in the life of a fleet and never per machine.
    ///
    /// **This is the only place the credential is asked for now**, with the first run. Settings had a standing
    /// page about it and has none since 20 October 2026, so both ways out of this one question stand here: the
    /// credential, which lets this Mac mint the key itself, and the prompt for the agent he already runs.
    private func network(_ again: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: FleetSpace.block) {
            FormSection {
                FormRow("Your server is not on your private network", symbol: "exclamationmark.triangle",
                        detail: String(l10n: "Connect your network, then install again. This Mac makes the key: used once, worthless in fifteen minutes."), warning: model.networkFailure)
            }
            PrivateNetworkSection(model: network, showsThisMac: false)
            // Once the network's credential is in place: never grey.
            if network.isHeld {
                Button("Install again") { again() }.buttonStyle(FleetPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("install-again-key")
                    .frame(maxWidth: .infinity)
            }
            NetworkPromptSection()
        }
    }

    /// The same page while the machine puts itself on the network: Tailscale printed a link, he approves it, and the
    /// install goes on by itself. This Mac makes no key here, so the row has no line about one.
    private func approve(_ signIn: NetworkSignIn) -> some View {
        FormSection {
            FormRow("Your server is not on your private network", symbol: "exclamationmark.triangle")
            FormRow(signIn.server.map { String(l10n: "Approve \($0) in Tailscale") } ?? String(l10n: "Approve in Tailscale"), symbol: "network") {
                Button("Open link") { NSWorkspace.shared.open(signIn.url) }
                    .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("install-network-sign-in")
            }
        }
    }

    private var run: some View {
        VStack(alignment: .leading, spacing: 22) {
            // **While the install runs, the step's moving title alone** (T-36's own change, fix round 2): its rows, the
            // lines the machine printed and the footer stood under it for the whole install. They are what a failure
            // needs, so they come with one. Under the title stand its four steps and the minutes left (`InstallPhases`).
            if model.failure == nil, model.running, InstallPhases(steps: model.steps, planned: model.planned) != nil {
                // The minutes go down within a long step too, so they are counted again every 20 seconds.
                TimelineView(.periodic(from: .now, by: 20)) { context in
                    if let phases = InstallPhases(steps: model.steps, planned: model.planned,
                                                  runningFor: context.date.timeIntervalSince(model.runningSince)) {
                        SetupPhases(names: InstallPhases.names, current: phases.current, minutesLeft: phases.minutesLeft,
                                    status: showsStatus ? phases.status : nil)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("install-phases")
            }
            if model.failure != nil {
                FormSection(title, detail: detail) {
                    // **Each step by its name and its state, and nothing the machine printed** (fix round 3c, COPY): the
                    // failed step said the machine's own line in orange ("ssh: connect to host … Connection refused"),
                    // and its last three lines stood under the steps. The stop's one line says it in plain words, with
                    // the machine's words on its hover; the install's log keeps the rest.
                    ForEach(model.steps) { step in
                        FormRow(step.title, symbol: symbol(step)) {
                            if step.state != .running { Text(word(step)).font(SetupMetrics.textFont).foregroundStyle(tint(step)) }
                        }.accessibilityIdentifier("install-step-\(step.step)")
                    }
                }
            }
            if let failure = model.failure {
                // **What stopped, in a few plain words, over one Try again** (fix round 3, item 51): the line said the
                // machine's own last line, under an outline "Install again" that only went back to the form. The same
                // install runs again; the machine's own words stay on the line's hover, and Back goes to the form.
                FormSection(footer: String(l10n: "Each step checks first, so nothing is done twice.")) {
                    FormRow("The install stopped", symbol: "exclamationmark.triangle", warning: failure) {
                        Button("Try again") { if let again { again() } else { model.again() } }
                            .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("install-again")
                    }
                    .help(model.failureDetail ?? "")
                }
            }
            if let checklist = model.checklist {
                // **No checks while nothing but the sign-in is left** (fix round 3, item 49; D-2: a check shows only
                // while it has not passed): the sign-in is the step the setup goes on to, and the section said
                // "NOT READY: runtime_signed_in" under "Your fleet is up". A failed check keeps it, with its fix.
                if !checklist.isReady && !checklist.onlyNeedsSignIn {
                    VerifyChecklistView(checklist: checklist, subject: String(l10n: "this server"),
                                        footer: String(l10n: "Each failed check carries its own fix. Put it right, then check this server again from its page."))
                }
                // After a list of failed checks, the way on stays in view (`SetupAction`).
                SetupAction { next }
            }
        }
    }

    private var detail: String? {
        if model.running { return String(l10n: "Installing over your own SSH connection.") }
        if let checklist = model.checklist {
            return checklist.isReady || checklist.onlyNeedsSignIn ?
                String(l10n: "The install is done.") : String(l10n: "The install ended. Its checks are below.")
        }
        return nil
    }

    private func symbol(_ step: InstallProgress) -> String {
        switch step.state {
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        default: "circle.dashed"
        }
    }

    private func word(_ step: InstallProgress) -> String {
        switch step.state {
        case .done: String(l10n: "Done")
        case .failed: String(l10n: "Failed")
        default: String(l10n: "Waiting")
        }
    }

    private func tint(_ step: InstallProgress) -> Color {
        step.state == .failed ? .orange : FleetStyle.muted
    }
}
