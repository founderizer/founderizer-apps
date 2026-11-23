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
        /// The host for which the owner gave the port himself (`InstallTarget.portGivenFor`). A connection kept before
        /// 22 November 2026 has none, so its port, when it is not 22, is checked as a port of the hub's record: with
        /// the host key of its address's port 22, never one that an earlier run kept for that port.
        var portGivenFor: String?
    }

    static func remember(_ target: InstallTarget, machine: String, hub: URL) {
        var all = read()
        all[name(machine, hub: hub)] = Kept(host: target.host, user: target.user, port: target.port,
                                            identityFile: target.identityFile, portGivenFor: target.portGivenFor)
        if let data = try? JSONEncoder().encode(all) { AppDefaults.store.set(data, forKey: key) }
    }

    static func target(machine: String, hub: URL) -> InstallTarget? {
        guard let kept = read()[name(machine, hub: hub)] else { return nil }
        let target = InstallTarget(host: kept.host, user: kept.user, port: kept.port, identityFile: kept.identityFile,
                                   portGivenFor: kept.portGivenFor)
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
        if let data = try? JSONEncoder().encode(all) { AppDefaults.store.set(data, forKey: key) }
    }

    private static func read() -> [String: Kept] {
        guard let data = AppDefaults.store.data(forKey: key) else { return [:] }
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
            case .line: "Install by hand"
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
    /// The AI that the owner chose for a Mac that stays on, nil for a VPS, which is asked for none, and on a hub that
    /// takes no choice.
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
    /// The job of the install that runs or ran last, from its start on, so that a stop before its plan says it too
    /// (`setup_diagnosis`). `again` takes it away, so that an old job does not stand for a new page.
    private(set) var job: InstallJob?
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
    /// **The install's plain facts for `setup_diagnosis`** (`SetupChannel`, which reads it inside its observation): no
    /// write. Why it stopped goes as the fixed kind (`stop`), and never as the stop's words (`failure`,
    /// `failureDetail`), which stay with this model. It ended
    /// with its checklist, or with its task over and no stop: a Mac's installer that said done may send no checklist.
    var linkFacts: ReachFacts.InstallLink {
        ReachFacts.InstallLink(way: way.rawValue, running: running, failed: failure != nil,
                               ended: checklist != nil || (!running && failure == nil && work != nil),
                               job: job?.rawValue, steps: steps, planned: planned,
                               runningStep: steps.contains { $0.step == runningStep && $0.state == .running }
                                   ? runningStep : nil,
                               since: runningSince,
                               stop: stop, waitsForNetwork: needsNetworkKey, cause: cause, tries: log?.record.tries ?? 1)
    }
    /// What Tailscale said when this Mac tried to mint the key from the credential it holds. A credential that was
    /// ended or that expired leads to the same one question, and this is the line that says why it is being asked
    /// of a fleet that already answered it once.
    private(set) var networkFailure: String?
    /// The address this Mac claimed, after a hub install: the app connects to it by itself.
    private(set) var hubAddress: String?
    /// **Why the install stopped, as a fixed kind** (`InstallRecord.Stop`), beside `failure`, whose words are for the
    /// owner's eyes: nil exactly when `failure` is nil.
    private(set) var stop: InstallRecord.Stop?
    /// **Why the installer stopped itself, as a fixed name** (`InstallCause`): read from its own stop sentence at the
    /// stop, and from a Mac's sealed state only. nil with no stop, and for a stop that the installer did not give.
    private(set) var cause: InstallCause?
    /// **The kept record of this install** (`InstallRecord`), written at each change of a step's state and at the end,
    /// so that what happened can be read after this page is gone, after a restart and after an update of the app. It
    /// stays with the model after the end for a step's report that comes late, until the next install or `again`.
    private var log: InstallLog?
    private var work: Task<Void, Never>?
    /// **Which run the page follows**: each try of a press (`tries`) and each `again` makes a new one, and a step's
    /// report of an earlier run that comes late (a report goes to the main actor in a task of its own) is dropped, so
    /// that the steps of a retry never hold a step of the try before.
    private var runCount = 0
    /// The step that the last run of a plan stopped at (`InstallRetry.FailedStep`), for the retry's decision; nil when a
    /// try stopped before its plan ran.
    private var failedStep: String?

    /// The connection of the form, which is the owner's own word: the address and the port he typed, or what his
    /// check of that address (`InstallTarget.named`) or a provider's server gave, and after an install the machine's
    /// own private address (`MachineInstaller.reached`). No part of it comes from the hub's record, so its port is his
    /// for its host (`InstallTarget.portGivenFor`).
    var target: InstallTarget {
        let host = host.trimmingCharacters(in: .whitespaces)
        return InstallTarget(host: host, user: user.trimmingCharacters(in: .whitespaces), port: Int(port) ?? 0,
                             identityFile: identityFile, becomeRoot: user != "root", portGivenFor: host)
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

    /// The key this machine needs, or none when this Mac holds no way to make one: the machine is on the private network
    /// already, or it signs in by Tailscale's own link (`PrivateNetwork.joinKey`: the fleet's own key first). One key for
    /// one machine, used once, and worthless after `life` seconds: fifteen minutes, or two hours for a bare Mac. A key
    /// Tailscale refuses stops the install with Tailscale's own words, instead of installing a machine that cannot be
    /// reached.
    private func mintKey(for machine: String, life: Int = PrivateNetwork.keyLifeSeconds,
                         tags: [String] = [PrivateNetwork.tag]) async throws {
        let fleetKey = TailscaleFleetKey()
        do {
            // The credential of before is read only for a fleet that has no fleet key.
            authKey = try await PrivateNetwork.joinKey(for: machine, life: life, tags: tags, fleetKey: fleetKey,
                                                       credential: fleetKey.isHeld ? nil : NetworkCredentialStore.read()) ?? ""
        } catch {
            // A credential Tailscale no longer accepts asks the same question as a machine that is not on the
            // network, so it reaches the same screen instead of ending as one more line of a failed install.
            throw NetworkKeyRefused((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// **The name of a new hub's manager**, which its owner typed in the first run (`FirstRunModel.hubName`); nil for
    /// an install that did not ask, whose manager is `manager`. The first run sets it before each install of a hub.
    var managerName: String?
    /// **One server for all** (`FirstRunModel.oneServer`): the hub's installer gets the word for it, and the manager
    /// runs on the hub's own server. The first run sets it before each install of a hub.
    var oneServer = false
    /// **The step of the first run's slider** (`FirstRunModel.serversStep`), for the hub to keep from its first install
    /// on; nil for an install whose owner did not come through that page. The first run sets it before each install.
    var shape: ServersStep?
    /// **The manager's AI program** (`FirstRunModel.chosenAI`): with `oneServer` the hub's installer puts it on the
    /// hub's own server (`hub.sh --runtime`); nil for an install whose owner did not choose one. The first run sets it
    /// before each install.
    var runtime: String?
    /// **The server of the provider's list that this install runs on** ("Use this server"), by its provider and its id
    /// there, or nil: the install's end proves that server's build record by its id (`BuildRecords.noteJoined(serverID:)`),
    /// which a first run's record with no hub needs (the lane "Unfinished setup", 15 November 2026). The page that
    /// starts the install sets it after `use`, and `again` takes it away.
    var provenServer: (provider: CloudProvider, id: String)?
    /// **The agent that this install's server is for** (the review of 17 November 2026): the agent whose setup's page
    /// started it, or the new agent that Add agent's New server named; nil for a server for no agent yet. One install
    /// model serves every page of a hub, so its end can show on another agent's page, and Add server gives the server
    /// to this agent only (`AddServerView.handsOver`, `goesOn`). The page sets it once its start is taken (`running`):
    /// a start that the model refuses keeps the earlier install's end, and its agent with it. Try again keeps it, an
    /// agent's rename in its setup moves it (`AgentSetupView.rename`), and `again` takes it away.
    var forAgent: String?

    /// Installs the hub itself: the first machine of a fleet, which has no hub to ask for a line. The claim at its
    /// end proves this Mac's own address to that hub, and the app then connects to it.
    func installHub(store: FleetStore) {
        guard !running else { return }
        work?.cancel()      // the reading of a Mac's order before this one
        running = true; failure = nil; failureDetail = nil; needsNetworkKey = false; networkFailure = nil; steps = []; planned = []; checklist = nil
        job = .hub
        joinHub = nil
        // A new hub has no address yet: its record gets one at its claim step.
        begin(.hub, hub: nil, host: target.host)
        work = Task { [weak self] in
            guard let self else { return }
            await tries(job: .hub, store: store) { [weak self] _ in
                guard let self else { return }
                try await mintKey(for: "hub")
                let plan = InstallPlan.hub(target: target, source: source.trimmingCharacters(in: .whitespaces),
                                           authKey: authKey.isEmpty ? nil : authKey, managerName: managerName,
                                           oneServer: oneServer, shape: shape, runtime: runtime)
                try await run(plan: plan, store: store, machine: "hub")
            }
        }
    }

    /// **The hub that a join goes to**: its address, the database of its reading, and whether it asks for a server's
    /// name. The store's own hub (`installMachine(store:)`), or a hub that the store does not read yet: the first run's
    /// new hub right after its claim (slice 3 of the one wizard), whose join of the manager's server then runs while the
    /// hub's own install ends (the proof of 16 November 2026: a join began 20 seconds after a claim, during the hub's
    /// security updates, and ended with the self-test passed).
    struct JoinHub: Equatable {
        let url: URL
        let database: String
        let asksName: Bool
    }
    /// The hub of the join that runs or ran last; nil for a hub's install, which has its own address from its claim.
    private(set) var joinHub: JoinHub?

    /// Joins a machine to the hub this app is connected to: the hub gives the one-time line, and this Mac runs it
    /// over the owner's own connection. `hub`: another hub, with its database (`JoinHub`); the store's own when nil.
    func installMachine(store: FleetStore, at hub: JoinHub? = nil) {
        guard !running, let to = hub ?? store.state.map({
            JoinHub(url: store.hub, database: $0.db, asksName: Servers.asksName($0.ui_features))
        }) else { return }
        let database = to.database
        // A hub with `server_names` names the server by its name in Tailscale at its join, so it is sent no name.
        let machine = to.asksName ? name : nil
        work?.cancel()      // the reading of a Mac's order before this one
        running = true; failure = nil; failureDetail = nil; needsNetworkKey = false; networkFailure = nil; steps = []; planned = []; checklist = nil
        job = .join
        // Only another hub is kept: a join to the store's own reads the store's hub and database as before.
        joinHub = hub
        server = machine; made = nil
        begin(.join, hub: to.url.absoluteString, host: target.host, server: machine)
        work = Task { [weak self] in
            guard let self else { return }
            // **A retry runs the same line** (`InstallRetry.freshCode`): the hub takes the same server's repeat of a
            // used code, and a new code would end every other open code of the hub, and with it any other join that
            // has not sent its code yet. Only an expired code, a code with too little time left
            // (`InstallRetry.keepsCode`), or a try that got no line, asks for a new one.
            var given: (line: String, code: String)?
            await tries(job: .join, store: store) { [weak self] freshCode in
                guard let self else { return }
                if freshCode || given == nil
                    || !InstallRetry.keepsCode(expiresAt: made?.expiresAt ?? 0, now: Date().timeIntervalSince1970) {
                    given = nil; made = nil
                    let join = try await HubClient().joinCode(hub: self.joinHub?.url ?? store.hub, database: database,
                                                              client: store.installation, name: machine, kind: "linux")
                    made = (join.name, join.kind, join.expires_at)
                    guard let line = join.line, let code = join.code else {
                        throw InstallError.cannotStart(String(l10n: "The hub gave no join line. Try again."))
                    }
                    given = (line, code)
                }
                guard let kept = given else {
                    throw InstallError.cannotStart(String(l10n: "The hub gave no join line. Try again."))
                }
                let (line, code) = kept
                // The key carries the tags of the hub's own join line, as the sign-in link does, so the server has
                // the tags by which the tailnet's policy gives the fleet's machines their rights. A credential that
                // may not give those tags leaves the server to the link, which the owner approves.
                let tags = NetworkSignIn.tags(inLine: line)
                do { try await mintKey(for: machine ?? target.host, tags: tags.isEmpty ? [PrivateNetwork.tag] : tags) }
                catch is NetworkKeyRefused where !tags.isEmpty { authKey = "" }
                let plan = InstallPlan.join(target: target, line: line, code: code,
                                            authKey: authKey.isEmpty ? nil : authKey)
                try await run(plan: plan, store: store, machine: machine)
            }
        }
    }

    /// **One press, up to three tries** (`InstallRetry`; the owner's "Yes, build it" of 16 November 2026 to the plan
    /// `install-auto-repair-plan.md`): a try that stopped for an error that passes runs again by itself. The page stays
    /// the running page, its steps counted again from the plan (`InstallPhases` with `planned`), so **nothing new
    /// shows**; the record follows the next try and counts it (`InstallLog.retry`); after the last try the stop shows as
    /// before. A press that gave a sudo password gets no retry: `run` lets go of the password after each run, on purpose,
    /// so it is noted here, before the first run. `once` gets whether a join asks for a new code (`freshCode`). A cancel
    /// ends the press, its retries and their waits included, and shows no stop: `cancel()` ended the record already,
    /// and the error is a try's that the cancel cut off, or one of a try before the wait that the owner never saw
    /// (a review of 16 November 2026; `linkMac` does the same).
    private func tries(job: InstallJob, store: FleetStore,
                       once: @escaping (_ freshCode: Bool) async throws -> Void) async {
        let usedSudoPassword = sudoPassword != nil
        var tries = 1, freshCode = false
        while true {
            runCount += 1
            failedStep = nil
            do {
                try await once(freshCode)
                return
            } catch {
                guard !Task.isCancelled else { return }
                let stopped = InstallRetry.stopped(by: error, networkKeyRefused: error is NetworkKeyRefused,
                                                   authKeyEmpty: authKey.isEmpty)
                guard let retry = InstallRetry.decision(stop: stopped.stop, cause: stopped.cause, job: job,
                                                        step: failedStep, tries: tries,
                                                        needsNetworkKey: stopped.needsNetworkKey,
                                                        usedSudoPassword: usedSudoPassword)
                else { return finish(error: error) }
                tries += 1
                freshCode = retry.freshCode
                if log?.retry(after: stopped.stop, cause: stopped.cause) == true { keepRecord() }
                runCount += 1
                steps = []
                // Reads of this Mac's hub at the pace of the wait for a server (`InstallRetry.readEvery`).
                await InstallRetry.wait(retry.wait,
                                        pause: { try? await Task.sleep(for: .seconds(InstallRetry.readEvery)) },
                                        read: { await MachineInstaller.readHub(at: self.joinHub?.url ?? store.hub) != .silent },
                                        cancelled: { Task.isCancelled })
                guard !Task.isCancelled else { return }
            }
        }
    }

    /// Links **a Mac that stays on**: the hub's one-time line goes to the installer that runs there, with the link
    /// code the owner read off its screen. The app then reads that installer until the install ends. `withAgent`
    /// false: the order names no first agent, because the Mac is the server of an agent that the fleet has already (the
    /// manager of a new fleet, which the hub refuses as a Mac's new agent). `named`: the name that he gave that agent on
    /// Add agent, whose New server opened this install; else the name that Add agent would suggest.
    func linkMac(store: FleetStore, withAgent: Bool = true, named: String? = nil) {
        guard !running, let database = store.state?.db else { return }
        guard let installer = MacInstallerClient.address(macHost), let code = ClaimCode.read(linkCode) else {
            cannotLink(MacLinkError.notAnAddress.errorDescription)
            return
        }
        guard Servers.setsUpMacs(store.state?.ui_features) else {
            // The sidebar's Update takes a release of the fleet (`UpdateBanner`): Settings › Updates is gone since
            // 15 November 2026. Add server fills the window, which has no sidebar, so the page is closed first (the
            // owner's choice of 19 November 2026 of these words, "Close this page first").
            cannotLink(String(l10n: "Your hub needs the newest Founderizer first. Close this page, then press Update in the sidebar."))
            return
        }
        // A hub with `server_names` names this Mac by its name in Tailscale at its join, so its code is made with no
        // name. The installer is still sent a name the hub allows: its older copies refuse an order without one.
        let asks = Servers.asksName(store.state?.ui_features)
        let machine = asks || Servers.nameProblem(name, taken: []) == nil ? name : Servers.suggestedName(taken: [])
        // The first agent of this Mac: the name he gave it on Add agent, or the name Add agent would suggest. The hub adds
        // it once this Mac has joined.
        firstAgent = withAgent ? named ?? AddAgentModel.freeName(taken: Set(store.state?.agents.map(\.name) ?? [])) : nil
        work?.cancel()      // the reading of the order before this one
        // No wait for the network of an install before this one, as the two other installs begin: with it still
        // set, this link was drawn as the network's question while it ran and after its good end (`MachineInstallRun`).
        running = true; failure = nil; failureDetail = nil; needsNetworkKey = false; networkFailure = nil; steps = []; planned = []; checklist = nil
        job = .join
        joinHub = nil
        server = asks ? machine : nil; made = nil
        begin(.mac, hub: store.hub.absoluteString, host: installer.host ?? "", server: asks ? machine : nil)
        // The link code seals the order: it is in no kept word.
        log?.hide([code])
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
                log?.hide([authKey])
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
                        if failure == nil { finish(error: MacLinkError.refused(state.says), sealed: state.says) }
                        continue
                    }
                    if failure != nil {
                        running = true; failure = nil; failureDetail = nil; needsNetworkKey = false; networkFailure = nil
                        stop = nil; cause = nil
                        // The record runs again, and holds the link code again for a line that it may keep.
                        if log?.goOn() == true { log?.hide([code]); keepRecord() }
                    }
                    if state.isDone {
                        let named = asks ? machine : await joinedName(store: store)
                        server = named
                        // Add server for that machine on this Mac: a removal mark of it goes (package 4 of the vault's gates).
                        if let named { store.vaultModel().added(named) }
                        checklist = state.checklist
                        running = false
                        log?.place(server: named)
                        log?.done()
                        keepRecord()
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
        log?.hide(plan.redactions)
        let installer = MachineInstaller(plan: plan, authKey: authKey, sudoPassword: sudoPassword)
        defer { sudoPassword = nil }
        let answer: VerifyChecklist
        let thisRun = runCount, failed = InstallRetry.FailedStep()
        do {
            answer = try await installer.run { progress in
                failed.note(progress)
                Task { @MainActor [weak self] in
                    guard let self, runCount == thisRun else { return }
                    record(progress)
                }
            }
        } catch {
            failedStep = failed.value
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
        log?.place(hub: plan.job == .hub ? claimedHub() : nil, host: reached.host, server: machine)
        log?.done()
        keepRecord()
        guard let machine else { return }
        // The hub of a join, which the store may not read yet (`JoinHub`); the store's own for a hub's install.
        let fleet = plan.job == .join ? joinHub?.url ?? store.hub : store.hub
        // Add server for that machine on this Mac: a removal mark of it goes (package 4 of the vault's gates). The
        // vault's marks are the store's hub's.
        if fleet == store.hub { store.vaultModel().added(machine) }
        InstallTargets.remember(reached, machine: machine, hub: fleet)
        MachineChecks.remember(answer, machine: machine, hub: fleet)
        // A server's install ran to its last step from this Mac (`InstallEnds`).
        if plan.job == .join {
            InstallEnds.note(machine, address: reached.host, hub: fleet)
            // A server that this Mac made for this hub and never saw join did join after all (`BuildRecord`): by the
            // hub that this install began with.
            let hub = log?.record.hub ?? fleet.absoluteString
            BuildRecords.shared.noteJoined(name: machine, hub: hub)
            // A server of the provider's list is proved by its id too, also when its record has no hub.
            if let proven = provenServer {
                BuildRecords.shared.noteJoined(serverID: proven.id, provider: proven.provider, hub: hub)
            }
        }
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
            // The hub's own server, when "Use this server" chose it in the first run: by its id, for the hub's address
            // that the claim gave.
            if let proven = provenServer {
                BuildRecords.shared.noteJoined(serverID: proven.id, provider: proven.provider, hub: store.hub.absoluteString)
            }
        }
    }

    /// The name the hub gave the server that joined with this install's code (`server_names`): its join state has it
    /// from the join's commit, which the install's last step comes after. Up to five reads, three seconds apart, for a
    /// hub that is slow to answer; nil after them.
    private func joinedName(store: FleetStore) async -> String? {
        let hub = joinHub?.url ?? store.hub
        guard let made, let database = joinHub?.database ?? store.state?.db else { return nil }
        for read in 0..<5 {
            if read > 0 { try? await Task.sleep(for: .seconds(3)) }
            guard !Task.isCancelled else { return nil }
            if let join = (try? await HubClient().servers(hub: hub, database: database))?.join,
               join.isOf(name: made.name, kind: made.kind, expiresAt: made.expiresAt), join.state == "joined",
               let server = join.server { return server }
        }
        return nil
    }

    /// **The new hub's address once its claim step is done** (a hub's install), for a join that goes to it before the
    /// store reads it (`JoinHub`); nil before.
    var claimedHubURL: URL? {
        guard steps.contains(where: { $0.step == "claim" && $0.state == .done }) else { return nil }
        return claimedAddress().flatMap { try? HubClient.address($0) }
    }

    /// The hub's own address, out of the claim step this install already made.
    private func claimedAddress() -> String? {
        for step in steps.reversed() where step.step == "claim" {
            if let claimed = StartAgain.claimedHub(in: step.lines) { return claimed }
        }
        return nil
    }

    private func record(_ progress: InstallProgress) {
        if let at = steps.firstIndex(where: { $0.step == progress.step }) { steps[at] = progress } else { steps.append(progress) }
        let now = steps.first(where: { $0.state == .running })?.step
        if now != runningStep { runningStep = now; runningSince = Date() }
        // The kept record: a step that began or ended, never a line that it printed. A hub has its address from its
        // claim step on, so a stop after it is kept by that address.
        var changed = log?.note(step: progress.step, state: progress.state == .done ? .done
                                    : progress.state == .failed ? .failed : .running) == true
        if progress.step == "claim", progress.state == .done, log?.place(hub: claimedHub()) == true { changed = true }
        if changed { keepRecord() }
    }

    /// **A Mac's link that cannot start**: its own line and its own kind of stop, with no cause and no wait for the
    /// network of the install before it. While that wait stayed set, `setup_diagnosis` said that the install waits
    /// for the network beside `cannot_start` (seen by a review of the lane "Agent install", 15 November 2026). The
    /// steps, the checklist and the record of the install before it stay as they are, as before. Add server's Back
    /// from the install page starts the model again after a stop (`AddMachineView`, its `back`): this line shows on
    /// the Mac's form, where Back starts nothing again.
    private func cannotLink(_ words: String?) {
        failure = words; failureDetail = nil
        needsNetworkKey = false; networkFailure = nil
        stop = .cannotStart; cause = nil     // no cause of a stop before this one stands for this one
    }

    /// A new install begins: no stop, and a new record. `server`: the name that the owner gave it, on a hub that asks
    /// for one; else the hub names it at its join.
    private func begin(_ kind: InstallRecord.Kind, hub: String?, host: String, server: String? = nil) {
        stop = nil; cause = nil
        var log = InstallLog(kind: kind, hub: hub, host: host)
        log.place(server: server)
        self.log = log
        keepRecord()
    }

    /// Writes the record as it stands now (`InstallRecords`): one small file, and nothing when it did not change.
    private func keepRecord() {
        if let log { InstallRecords.shared.write(log.record) }
    }

    /// The claimed hub's address in the app's own form, only once the claim step ended well: the lines of a claim
    /// that failed hold the hub's address too, and that hub was never this Mac's.
    private func claimedHub() -> String? {
        guard steps.contains(where: { $0.step == "claim" && $0.state == .done }) else { return nil }
        return claimedAddress().map { (try? HubClient.address($0))?.absoluteString ?? $0 }
    }

    /// `sealed`: the stop sentence of a Mac's sealed state, the one sentence of another Mac that a cause is read from
    /// (a refusal that came in the clear may be a stranger's).
    private func finish(error: Error, sealed: String? = nil) {
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
        // The fixed kind of the stop, and the record's end. The page's own line is kept only where its words are this
        // app's own (`InstallRecord.words`): never the installer's own reason, a hub's, Tailscale's or a Mac's words.
        let kind: InstallRecord.Stop = error is NetworkKeyRefused ? .networkKeyRefused : .of(error)
        stop = kind
        // A server's address is the one that the install reached; a Mac's record keeps its installer's address.
        // **The record's kind is read before the call**: a call through `log?.` holds `log` for its whole length,
        // also while its arguments are read, so a read of `log` in them stopped the app (SIGABRT, Swift's check of
        // exclusive access) at each install that stopped, from 0.1.243 on (a user's report of 16 November 2026).
        let recorded = log?.record.kind
        log?.place(hub: recorded == .hub ? claimedHub() : nil, host: recorded == .mac ? nil : target.host)
        cause = InstallCause.of(error, sealed: sealed)
        log?.stop(kind, says: InstallRecord.words(of: error, host: target.host), cause: cause,
                  waitsForNetwork: needsNetworkKey)
        keepRecord()
    }

    func cancel() {
        work?.cancel(); work = nil
        running = false
        authKey = ""
        if log?.cancel() == true { keepRecord() }
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
        runCount += 1
        steps = []; planned = []; checklist = nil; failure = nil; failureDetail = nil; hubAddress = nil; needsNetworkKey = false; networkFailure = nil
        job = nil; joinHub = nil
        server = nil; made = nil; provenServer = nil; forAgent = nil
        // The record of the install that ended stays in its file; this model writes it no more.
        stop = nil; cause = nil; log = nil
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
    /// Puts a stop into the report form's box (the caller's `store.reportAsk`): the stop row's Report a problem, which
    /// then opens the form. Nil: the row has no such button.
    var report: ((ReportAsk) -> Void)?
    /// The hub that this install joins, for the prompt of a stop that the owner's agent can fix (`InstallFixPrompt`).
    /// Nil: no such row (the first run's own hub).
    var hub: URL?
    /// The line of what runs now under the title: the first run's "Building your fleet" only, which the owner approved
    /// on 5 November 2026.
    var showsStatus = false
    @Environment(\.openWindow) private var openWindow
    /// The prompt of this stop is on the clipboard: its button says Copied until the next stop.
    @State private var promptCopied = false

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
                // **No footer under it** (the owner, 16 November 2026, of "Each step checks first, so nothing is done
                // twice.": "that subtitle ... needs to be removed!"). **Report a problem beside Try again** (the owner,
                // the same day: "here we should have a button to Report... as we did in another thread"): it opens the
                // report form, and puts the stop and the server's last lines into its box (`InstallReport`) where the
                // box is free for the app's words (never over the owner's own text), as the manager band's Report a
                // problem does. **A stop that the owner's agent can fix says so in plain words, with a prompt for it**
                // (the owner, the same day, of a page that asked for a Tailscale key and policy lines: "No, too
                // technical. It should be something like Copy prompt to fix maybe instead?", and "Yes, build it" to its
                // picture): the line is the app's own sentence, and the row under it copies `InstallFixPrompt`, where
                // the technical part is. The installer's own words stay on the hover, in the report and in the prompt.
                let fixes = hub != nil && InstallFixPrompt.offers(job: model.job, cause: model.cause)
                FormSection {
                    FormRow("The install stopped", symbol: "exclamationmark.triangle",
                            warning: fixes ? InstallFixPrompt.stopLine : failure) {
                        HStack(spacing: 8) {
                            if let report {
                                Button("Report a problem") {
                                    let failed = model.steps.last { $0.state == .failed }
                                    report(ReportAsk(text: InstallReport.text(step: failed?.title, stop: failure,
                                                                              lines: failed?.lines ?? []),
                                                     byAgent: false))
                                    openWindow(id: FounderizerApp.reportWindow)
                                }
                                .buttonStyle(FleetOutlineButtonStyle())
                                .accessibilityIdentifier("install-report")
                            }
                            Button("Try again") { if let again { again() } else { model.again() } }
                                .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                                .accessibilityIdentifier("install-again")
                        }
                    }
                    .help(model.failureDetail ?? "")
                    if fixes {
                        FormRow("Your AI agent can fix this", symbol: "wrench.and.screwdriver",
                                detail: String(l10n: "Paste the prompt into your agent, then try again.")) {
                            Button(promptCopied ? "Copied" : "Copy prompt to fix") {
                                let failed = model.steps.last { $0.state == .failed }
                                copyMessage(InstallFixPrompt.text(server: model.server, address: model.host, hub: hub,
                                                                  said: failure, lines: failed?.lines ?? []))
                                promptCopied = true
                            }
                            .buttonStyle(FleetOutlineButtonStyle())
                            .accessibilityIdentifier("install-fix-prompt")
                        }
                    }
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
        // A new stop, or a new install, is a new prompt: its button says Copy again.
        .onChange(of: model.failure) { promptCopied = false }
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
