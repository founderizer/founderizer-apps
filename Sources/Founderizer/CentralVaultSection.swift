import FleetCore
import Observation
import SwiftUI

/// **The fleet's central vault, kept by this Mac by itself** (owner feature `central_vault`).
///
/// The owner, 24 October 2026: "this should be automatically setup, even under the hood if we dont need anything!"
/// So nothing here waits for a page or a button. The store's own poll ticks this model on every page, and about once
/// a minute it reads `GET /ui/vault` and does what `VaultPlan` decides: it installs the central vault on the hub's
/// machine over this Mac's SSH connection with this Mac's owner key, from root's own clone at its one fixed place
/// (`CentralVaultRemote.rootKit`), and pins the key that the install printed there, so that the hub's word is never the
/// only word about it; it makes a recovery code, keeps it in this Mac's keychain and nowhere else, and sends its key,
/// signed; and it pins each server whose vault key it reads over SSH, at an address that this Mac's own Tailscale says
/// is that server, and finds equal to the key the hub reports. When the vault runs another program than the hub's
/// release, it runs the install's root step again, which brings the vault up to date and keeps everything it holds.
/// A step that fails is tried again after 10 minutes, at most 6 times in a row, and then the Secrets page has a row for
/// it with Retry; the update has no row, and the next release's program starts its tries again.
///
/// At the end of a round it also keeps the hub's TCP window (`HubTCP`, the owner, 10 November 2026: "Yes, every
/// hub"): once for each hub, it runs `hubsetup.py tcp` from the same clone on the hub's machine, because a hub
/// installed before release 2026.11.293 gets that value from root only. That run is not a step of the plan and has no
/// row. The round waits for it, as it waits for the vault's own steps, and its outcome changes none of their tries.
///
/// It lives in the store, one for each hub address, so that a step that takes minutes goes on whatever page shows.
@MainActor @Observable
final class CentralVaultModel {
    private let hub: URL
    /// The last reading of `GET /ui/vault` for this hub generation.
    private(set) var reading: VaultReading?
    /// false: the hub answered 404, so it has no central vault and nothing new shows. nil: not read yet.
    private(set) var served: Bool?
    private var database: String?
    /// What the last reading decided: the step, and the rows of the Secrets page.
    private(set) var plan = VaultPlan.none
    /// A round runs now, by itself or for the owner's Retry or Set up.
    private(set) var working = false
    /// The row whose Retry or Set up runs now: "vault", or a machine.
    private(set) var acting: String?
    /// Why the owner's own Set up (taking the vault over) stopped.
    private(set) var takeOverProblem: String?
    private var lastRead: Date?
    private var hubOnRecord = false
    private var otherOwner = false
    private var install: VaultTries?
    private var recovery: VaultTries?
    private var servers: [String: VaultTries] = [:]
    /// The tries of the update, and the program of the hub's release they were for.
    private var update: VaultTries?
    private var updateFor: String?
    /// The tries of the hub's TCP step (`HubTCP`), and the hub's release they were for. A done step is kept in this
    /// Mac's defaults, not here.
    private var tcpWindow: VaultTries?
    private var tcpWindowFor: String?
    /// What the vault confirmed in this session, which the hub's reading shows up to a minute later, because the hub
    /// reads the vault's status once a minute. Without them a pin would read as missing for that minute.
    private var confirmedRecovery: String?
    private var confirmedPins: [String: String] = [:]
    /// When this session last signed each machine's pin (`VaultFacts.signedAt`).
    private var signedAt: [String: Double] = [:]

    init(hub: URL) { self.hub = hub }

    /// The central vault serves this hub now: it sends each server its secrets by grant, so the page shows no second
    /// way to put a copy into a machine's vault.
    var inUse: Bool { served == true && reading?.central?.ok == true }

    // MARK: the poll

    /// Called from the store's poll, every few seconds on every page: it reads the vault once a minute (a hub without
    /// one every 5 minutes), and does nothing else in between. A wake of the hub's change signal (`woken`) reads it at
    /// once on a hub that has one, because the vault's state is one of the changes the hub announces.
    func tick(store: FleetStore, now: Date = Date(), woken: Bool = false) {
        guard !working, store.hub == hub, store.isFresh, store.state?.db != nil else { return }
        guard (woken && served == true)
                || lastRead.map({ now.timeIntervalSince($0) >= (served == false ? 300 : 60) }) ?? true else { return }
        lastRead = now
        working = true
        Task {
            await rounds(store)
            working = false
        }
    }

    /// Read, decide, act, and again: an install goes on to its recovery key and its servers in one go. Each step leaves
    /// the facts changed, by its success or by its try, so the rounds end; five is more than one install needs.
    private func rounds(_ store: FleetStore) async {
        for _ in 0..<5 {
            guard await read(store) else { return }
            switch plan.step {
            case .install: await installOwn(store)
            case .recover: await recover(store)
            case .update: await updateOwn(store)
            case .trust(let machines): for machine in machines { await trust(machine, store) }
            case .nothing, .takeOver:
                await keepTCPWindow(store)
                return
            }
        }
        _ = await read(store)
    }

    /// One reading and the plan it gives. A failed read keeps the last reading and decides nothing.
    private func read(_ store: FleetStore) async -> Bool {
        guard store.hub == hub, store.isFresh, let database = store.state?.db else { return false }
        // nil is an answer here, a hub without the vault (404); a failed read is not.
        let fresh: VaultReading?
        do { fresh = try await VaultClient().reading(hub: hub, database: database) } catch { return false }
        guard store.hub == hub, store.state?.db == database else { return false }
        if self.database != database {        // another generation starts clean
            install = nil; recovery = nil; servers = [:]; otherOwner = false; takeOverProblem = nil
            confirmedRecovery = nil; confirmedPins = [:]; update = nil; updateFor = nil; tcpWindow = nil; tcpWindowFor = nil
            // signedAt stays: a new generation of the hub does not shorten the day of wait after a signature.
        }
        if fresh?.program != updateFor { update = nil }       // the tries were for another release's program
        self.database = database
        served = fresh != nil
        reading = fresh
        if let fresh, fresh.central == nil {
            // The install runs only on a hub machine that the fleet has an SSH connection on record for. A hub that
            // names the vault's machine gives its record; an older one, the manager's machine, as before.
            if let own = fresh.hub {
                hubOnRecord = own.reach.onRecord != nil || InstallTargets.target(machine: own.machine, hub: hub) != nil
            } else {
                let machines = try? await HubClient().machines(hub: hub, database: database).machines
                hubOnRecord = machines.flatMap { MachineReach.of(CentralVault.hubMachine(in: $0), in: $0)?.onRecord } != nil
            }
        }
        plan = VaultPlan.of(fresh, facts: facts)
        return true
    }

    private var facts: VaultFacts {
        let fleet = reading?.fleetID
        return VaultFacts(keyHeld: fleet.map(OwnerKeychain.isHeld) ?? false,
                          pin: fleet.flatMap { CentralVaultPins.recipient(hub: hub, fleet: $0) }, hubOnRecord: hubOnRecord,
                          otherOwner: otherOwner, confirmedRecovery: confirmedRecovery, confirmedPins: confirmedPins, signedAt: signedAt,
                          install: install, recovery: recovery, servers: servers, update: update,
                          now: Date().timeIntervalSince1970)
    }

    // MARK: the owner's own presses

    /// Retry on the Founderizer Vault row: the step that gave up, once more now. Another failure keeps the row, with
    /// the new reason; it does not start the automatic tries again.
    func retry(_ store: FleetStore) {
        guard !working, case .retry(let step, _)? = plan.vault else { return }
        run("vault", store) { model in
            switch step {
            case .install: await model.installOwn(store)
            case .recover: await model.recover(store)
            default: break
            }
        }
    }

    /// Retry on a server's row: its key read and pinned once more now.
    func retry(server machine: String, _ store: FleetStore) {
        guard !working else { return }
        run(machine, store) { model in await model.trust(machine, store) }
    }

    /// Set up, only where the vault is not this Mac's to act on: the install without the check that a vault there is
    /// this Mac's, so its owner key becomes this Mac's and another Mac's key no longer signs for it.
    func takeOver(_ store: FleetStore) {
        guard !working, case .setUp? = plan.vault else { return }
        takeOverProblem = nil
        run("vault", store) { model in
            switch await model.installed(store, own: false) {
            case .done: model.install = nil; model.otherOwner = false
            case .stopped(let says): model.takeOverProblem = says
            case .otherOwner: break         // only the app's own install stops there
            }
        }
    }

    private func run(_ row: String, _ store: FleetStore, _ action: @escaping @MainActor (CentralVaultModel) async -> Void) {
        working = true; acting = row
        Task {
            await action(self)
            acting = nil
            await rounds(store)
            working = false
        }
    }

    // MARK: the steps

    private enum Outcome { case done, stopped(String), otherOwner }

    /// A stop of a step, in the owner's words.
    private struct Stop: LocalizedError {
        let says: String
        init(_ says: String) { self.says = says }
        var errorDescription: String? { says }
    }

    /// The app's own install, and its try.
    private func installOwn(_ store: FleetStore) async {
        switch await installed(store, own: true) {
        case .done: install = nil; otherOwner = false
        case .stopped(let says): install = VaultTries.failed(after: install, at: Date().timeIntervalSince1970, reason: says)
        case .otherOwner: otherOwner = true
        }
    }

    /// The vault's update, when it runs another program than the hub's release: the app's own install again
    /// (`--keep-owner`), done only once the hub reads the vault with the release's program. Its tries are for that one
    /// program: the next release's starts them again.
    private func updateOwn(_ store: FleetStore) async {
        guard let program = reading?.program else { return }
        let outcome = await installed(store, own: true, program: program)
        switch outcome {
        case .done: update = nil
        case .stopped(let says):
            update = VaultTries.failed(after: updateFor == program ? update : nil, at: Date().timeIntervalSince1970, reason: says)
        case .otherOwner:
            update = VaultTries.failed(after: updateFor == program ? update : nil, at: Date().timeIntervalSince1970,
                                       reason: String(l10n: "The central vault on the hub's server holds another Mac's owner key."))
        }
        updateFor = program
    }

    /// **The hub's TCP window** (`HubTCP.round`), at the end of a round: once for each hub, the step's own run as root
    /// on the hub's machine, which this Mac reaches as for the install, with the strict check of the host key. The round
    /// waits for it, as it waits for the vault's own steps, so this app starts no two runs of root's clone at once. The
    /// run needs a few seconds; its time-out is the install's, 15 minutes, because its `kit-clone` can also make root's
    /// first clone. Its outcome sets only its own tries, or keeps the hub as done. The hub's release is this launch's
    /// reading, or the one kept from the last launch (as for the Update row), and the tries start again when the hub
    /// takes another release, which can bring the step.
    private func keepTCPWindow(_ store: FleetStore) async {
        guard store.hub == hub, store.isFresh, let database = store.state?.db, database == self.database else { return }
        let releases = store.reading("releases") as ReleaseState? ?? store.keptReleases.reading(of: database)
        let release = releases?.current?.version
        (tcpWindow, tcpWindowFor) = HubTCP.tries(tcpWindow, for: release, after: tcpWindowFor)
        let hub = hub, reading = reading
        tcpWindow = await HubTCP.round(reading, hub: hub, release: release, tries: tcpWindow) { program in
            let machine: String
            if let own = reading?.hub?.machine {
                machine = own
            } else {
                machine = CentralVault.hubMachine(in: try await HubClient().machines(hub: hub, database: database).machines)
            }
            let target = try await self.target(machine, database: database, record: reading?.hub?.reach)
            return try await LocalShell.run("/usr/bin/ssh", CentralVaultRemote.arguments(target: target, program: program),
                                            timeout: 900).output
        }
    }

    /// **One root step of root's own clone on the hub's machine, for another part of this app** (the connected apps'
    /// `connect on|off`, `ConnectGate.program`): the hub's machine reached as for the install and the TCP step, with the
    /// strict check of the host key. It waits while a round of this model runs, and no round starts while it runs, so
    /// this app starts no two runs of root's clone at once. The time-out is the install's, because its `kit-clone` can
    /// also make root's first clone.
    func rootRun(_ program: String, store: FleetStore) async throws -> LocalShell.Answer {
        while working { _ = try await store.nap(2) }
        working = true
        defer { working = false }
        guard store.hub == hub, let database = store.state?.db else { throw Stop(String(l10n: "Founderizer has no current status of the hub.")) }
        let machine: String
        if let own = reading?.hub?.machine {
            machine = own
        } else {
            machine = CentralVault.hubMachine(in: try await HubClient().machines(hub: hub, database: database).machines)
        }
        let target = try await self.target(machine, database: database, record: reading?.hub?.reach)
        return try await LocalShell.run("/usr/bin/ssh", CentralVaultRemote.arguments(target: target, program: program),
                                        timeout: 900)
    }

    /// The install on the hub's machine, from root's own clone there, the pin of the key it printed, and the hub's
    /// reading of that same key. `own`: the app's own install, which leaves a vault that another Mac's key holds as it
    /// is (`--keep-owner`). `program`: the update to that program of the hub's release, which is done only when the
    /// hub reads the vault running it.
    private func installed(_ store: FleetStore, own: Bool, program release: String? = nil) async -> Outcome {
        do {
            guard store.hub == hub, store.isFresh, let database = store.state?.db else {
                throw Stop(String(l10n: "Founderizer has no current status of the hub."))
            }
            guard let reading = try await VaultClient().reading(hub: hub, database: database) else { throw Stop(String(l10n: "This hub has no central vault.")) }
            guard let fleet = reading.fleetID else { throw Stop(String(l10n: "The hub did not say which fleet this is.")) }
            let key = try OwnerKeychain.key(fleet: fleet) ?? OwnerKeychain.make(fleet: fleet)
            guard let program = CentralVaultRemote.install(ownerKey: key.publicKey, keepOwner: own) else {
                throw Stop(String(l10n: "Founderizer cannot write the install for this owner key."))
            }
            let machine: String
            if let own = reading.hub?.machine {
                machine = own
            } else {
                machine = CentralVault.hubMachine(in: try await HubClient().machines(hub: hub, database: database).machines)
            }
            let target = try await self.target(machine, database: database, record: reading.hub?.reach)
            let answer = try await LocalShell.run("/usr/bin/ssh", CentralVaultRemote.arguments(target: target, program: program), timeout: 900)
            let recipient: String
            switch CentralVaultRemote.installed(answer.output) {
            case .installed(let vaultKey, let printed)?:
                guard printed == fleet else {
                    throw Stop(String(l10n: "The vault on \(machine) belongs to the fleet \(printed), and the hub is \(fleet). Founderizer pinned nothing."))
                }
                recipient = vaultKey
            case .otherOwner?: return .otherOwner
            case .refused(let says)?: throw Stop(String(l10n: "The install on \(machine) stopped: \(says)"))
            case nil: throw Stop(Self.unread(answer, machine: machine, what: String(l10n: "the install's answer")))
            }
            // The key the machine printed is the pin. Nothing is sealed to the vault before the hub names that same key.
            CentralVaultPins.pin(recipient, hub: hub, fleet: fleet)
            // The hub reads the vault's status at most once a minute, so a reading from before the install can still
            // name nothing, or the key of a vault this install replaced. Three minutes is three of its readings.
            for _ in 0..<36 {
                if let fresh = try? await VaultClient().reading(hub: hub, database: database), fresh.central?.ok == true,
                   fresh.central?.recipient == recipient, release == nil || fresh.central?.source == release { return .done }
                try await store.nap(5)
            }
            throw Stop(release == nil ? String(l10n: "The hub has not read the vault on \(machine) with the key its install printed.")
                                      : String(l10n: "The hub has not read the vault on \(machine) with the program of its release."))
        } catch {
            return .stopped(Self.words(error))
        }
    }

    /// The recovery key: the code this Mac keeps in its keychain for the fleet, made now when it keeps none, and its
    /// key signed and sent. The code itself goes nowhere.
    private func recover(_ store: FleetStore) async {
        do {
            guard store.hub == hub, store.isFresh, let database = store.state?.db, let fleet = reading?.fleetID,
                  let key = OwnerKeychain.key(fleet: fleet) else {
                throw Stop(String(l10n: "Founderizer has no current status of the hub, or no owner key for it."))
            }
            let code = try RecoveryKeychain.kept(fleet: fleet)
            let statement = OwnerStatement.recovery(fleet: fleet, recipient: code.recipient)
            _ = try await VaultClient().recovery(hub: hub, database: database, client: store.installation, statement: statement,
                                                 signature: key.sign(statement))
            confirmedRecovery = code.recipient
            recovery = nil
        } catch {
            recovery = VaultTries.failed(after: recovery, at: Date().timeIntervalSince1970, reason: Self.words(error))
        }
    }

    /// One server: its vault key read over SSH, and pinned when it is the key the hub reports for it. The address of
    /// the connection must be that server's, as this Mac's own Tailscale says (`MacNetwork.device(of:)`), because it
    /// can come from the hub's record. A Linux server's key is read as root from its broker's configuration; a Mac's
    /// is Founderizer Vault's own `status`, asked as the user it serves, with no `sudo` (DevOps plan V4).
    private func trust(_ name: String, _ store: FleetStore) async {
        do {
            guard store.hub == hub, store.isFresh, let database = store.state?.db, let fleet = reading?.fleetID,
                  let key = OwnerKeychain.key(fleet: fleet) else {
                throw Stop(String(l10n: "Founderizer has no current status of the hub, or no owner key for it."))
            }
            guard let machine = reading?.machines.first(where: { $0.machine == name }), let reported = machine.broker_recipient,
                  machine.canBeTrusted else { throw Stop(String(l10n: "The hub reports no vault key for \(name) now.")) }
            var target = try await self.target(name, database: database)
            guard await MacNetwork.device(of: target.host) == name else {
                throw Stop(String(l10n: "This Mac's Tailscale does not say that \(target.host) is \(name). Founderizer pinned nothing."))
            }
            let mac = try await HubClient().servers(hub: hub, database: database).servers.first(where: { $0.name == name })?.kind == "mac"
            if mac { target.becomeRoot = false }
            let program = mac ? CentralVaultRemote.readMacVaultKey : CentralVaultRemote.readBrokerKey
            let answer = try await LocalShell.run("/usr/bin/ssh", CentralVaultRemote.arguments(target: target, program: program),
                                                  timeout: 120)
            guard let found = CentralVaultRemote.brokerKey(in: answer.output) else {
                throw Stop(Self.unread(answer, machine: name, what: String(l10n: "its vault key")))
            }
            guard found == reported else {
                throw Stop(String(l10n: "The vault key on \(name) is not the one the hub reports for it. Founderizer pinned nothing."))
            }
            let statement = OwnerStatement.pin(fleet: fleet, machine: name, recipient: found)
            _ = try await VaultClient().pin(hub: hub, database: database, client: store.installation, statement: statement,
                                            signature: key.sign(statement))
            confirmedPins[name] = found
            signedAt[name] = Date().timeIntervalSince1970
            servers[name] = nil
        } catch {
            servers[name] = VaultTries.failed(after: servers[name], at: Date().timeIntervalSince1970, reason: Self.words(error))
        }
    }

    /// How this Mac reaches one machine: the connection it keeps for it, else the fleet's own record of it. A user
    /// who is not root becomes root with `sudo -n`, so nothing waits for a password.
    private func target(_ machine: String, database: String, record: MachineReach? = nil) async throws -> InstallTarget {
        if var kept = InstallTargets.target(machine: machine, hub: hub) {
            kept.becomeRoot = kept.user != "root"
            // A public address lets no SSH in once the machine's installer has run (`MachineReach.reaching`). The list
            // of servers has the private address also of a server that runs no agent yet.
            if InstallTarget.isPublicAddress(kept.host),
               let address = try await HubClient().servers(hub: hub, database: database).servers
                   .first(where: { $0.name == machine })?.address {
                kept = MachineReach(address: address).reaching(kept)
            }
            return kept
        }
        let fleets: MachineReach?
        if let record {
            fleets = record
        } else {
            fleets = MachineReach.of(machine, in: try await HubClient().machines(hub: hub, database: database).machines)
        }
        guard let known = fleets?.onRecord else {
            throw Stop(String(l10n: "The fleet has no SSH connection to \(machine) on record. Record one on its page in Servers."))
        }
        let target = InstallTarget(host: known.address, user: known.user, port: known.port, becomeRoot: known.user != "root")
        guard target.isValid else { throw Stop(target.problem ?? String(l10n: "The fleet's record of \(machine) is not a connection.")) }
        return target
    }

    /// What an answer over SSH says when it lacks the line Founderizer reads: the host key this Mac does not know
    /// (the vault's steps check it strictly), or the machine's own last line.
    private static func unread(_ answer: LocalShell.Answer, machine: String, what: String) -> String {
        if answer.lines.contains(where: { $0.contains("Host key verification failed") }) {
            return String(l10n: "This Mac does not know the host key of \(machine) yet. Connect to it once with ssh from Terminal.")
        }
        // Plain words only (T-35): the machine's own last line was appended to this one.
        return String(l10n: "Founderizer could not read \(what) on \(machine).")
    }

    private static func words(_ error: Error) -> String {
        HubError.said(error) ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

}

/// **The top of the Secrets page, only while the central vault needs the owner**: the Founderizer Vault row when an
/// automatic step gave up (its "!" and Retry) or when the vault is not this Mac's to act on (Set up), and one row for
/// each server the automatic trust gave up on (its "!" and Retry). With everything in order there is no row at all.
struct CentralVaultSection: View {
    @Bindable var store: FleetStore
    @Bindable var model: CentralVaultModel

    var body: some View {
        if model.plan.vault != nil || !model.plan.servers.isEmpty {
            FormSection {
                if let need = model.plan.vault {
                    FormRow("Founderizer Vault", symbol: "lock.shield") { vaultControl(need) }
                        .accessibilityIdentifier("vault-row")
                }
                ForEach(model.plan.servers) { server in
                    FormRow(server.machine, symbol: "server.rack") {
                        control(row: server.machine, reason: server.reason, words: String(l10n: "Try again")) { model.retry(server: server.machine, store) }
                    }.accessibilityIdentifier("vault-server-\(server.machine)")
                }
            }
        }
    }

    @ViewBuilder private func vaultControl(_ need: VaultNeed) -> some View {
        switch need {
        case .retry(_, let reason):
            control(row: "vault", reason: reason, words: String(l10n: "Try again")) { model.retry(store) }
        case .setUp(let reason):
            control(row: "vault", reason: model.takeOverProblem ?? reason, words: String(l10n: "Set up")) { model.takeOver(store) }
                .help("Take the vault over on this Mac. Its owner key becomes this Mac's.")
        }
    }

    /// A "!" with the reason on hover where there is one, and one button; a spinner while that row's press runs.
    @ViewBuilder private func control(row: String, reason: String?, words: String, action: @escaping () -> Void) -> some View {
        if model.acting == row {
            ProgressView().controlSize(.small).accessibilityLabel("Working")
        } else {
            HStack(spacing: 8) {
                if let reason {
                    Image(systemName: "exclamationmark.circle").font(IconMetrics.symbol(14)).foregroundStyle(.orange)
                        .help(reason).accessibilityLabel("Needs you").accessibilityValue(reason)
                }
                Button(words, action: action).buttonStyle(FleetOutlineButtonStyle()).disabled(!store.isFresh || model.working)
            }
        }
    }
}

/// **One row of a secret's detail: the servers that hold it**, a check for each server whose vault holds it now
/// (`held` of `GET /ui/vault`). Only with a hub that serves the central vault, only once that vault is set up, and
/// only when a server holds it.
struct CentralHeldRow: View {
    let model: CentralVaultModel
    let reference: String

    private var marks: [(machine: String, holds: Bool)] {
        guard model.inUse, let reading = model.reading else { return [] }
        return reading.machines.compactMap { machine in
            reading.held[machine.machine]?.contains(reference) == true ? (machine.machine, true) : nil
        }
    }

    var body: some View {
        let marks = self.marks
        if !marks.isEmpty {
            FormSection {
                FormRow("Servers", symbol: "server.rack") {
                    HStack(spacing: 14) {
                        ForEach(marks, id: \.machine) { mark in
                            let words = mark.holds ? String(l10n: "\(mark.machine) holds it") : String(l10n: "On its way to \(mark.machine)")
                            HStack(spacing: 5) {
                                Image(systemName: mark.holds ? "checkmark.circle.fill" : "clock")
                                    .foregroundStyle(mark.holds ? Color.green.opacity(0.85) : FleetStyle.muted)
                                Text(mark.machine).font(FormMetrics.detail).foregroundStyle(FleetStyle.text)
                            }
                            .help(words).accessibilityElement(children: .ignore).accessibilityLabel(words)
                        }
                    }
                }
            }.accessibilityIdentifier("secret-servers")
        }
    }
}
