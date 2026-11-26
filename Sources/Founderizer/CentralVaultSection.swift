import FleetCore
import Observation
import os
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
    private static let log = Logger(subsystem: "com.founderizer.app", category: "vault")
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
    /// The seed reads of this run of the app, by machine (`MacVaultPin.seedsDue`).
    private var seeds: [String: VaultTries] = [:]
    /// The servers that the owner removed on this Mac, kept in a file of this Mac (`VaultRemovals`) by the app's one
    /// keeper of it (`VaultRecordFiles`), which the model of each hub address uses and each round reads again; and the
    /// removals and Add servers of this session whose fleet the vault model has not read yet.
    private var removals: RecordKeeper<VaultRemovals> {
        get { VaultRecordFiles.removals }
        set { VaultRecordFiles.removals = newValue }
    }
    private var removedHere: [String: Double] = [:]
    private var addedHere: Set<String> = []
    /// The tries of each unpin that has not reached the central vault: one that fails waits `VaultTries.wait`, for ever.
    private var unpins: [String: VaultTries] = [:]
    /// **The key swap's own step** (Part B, app patch 2): this Mac's records on the disk (`KeySwapState`, also the
    /// tries of the update above, so that they outlive a start), the servers whose pin this session signed since their
    /// last key swap step (the weekly re-sign is one of its events), and the server rows that its stops give. The
    /// records are kept as the removals are (`VaultRecordFiles`).
    private var keySwap: RecordKeeper<KeySwapState> {
        get { VaultRecordFiles.keySwap }
        set { VaultRecordFiles.keySwap = newValue }
    }
    private var resigned: Set<String> = []
    private(set) var keySwapNeeds: [VaultServerNeed] = []
    /// The central vault's owner keys and fleet as this session last read them on the hub's machine, and when: read
    /// again only before a step (at most once in `KeySwapPlan.wait`), for the owner's Try again, and once in
    /// `keySwapKeysEvery`, so a round with no step opens no SSH session.
    private var keySwapKeys: (central: KeySwapCentral?, at: Date)?
    private static let keySwapKeysEvery: Double = 6 * 3600

    init(hub: URL) { self.hub = hub }

    /// The central vault serves this hub now: it sends each server its secrets by grant, so the page shows no second
    /// way to put a copy into a machine's vault.
    var inUse: Bool { served == true && reading?.central?.ok == true }

    /// The server rows of the Secrets page: each one whose trust gave up, then each other one whose key swap step needs
    /// the owner. One row for a server: the trust's reason first.
    var serverRows: [VaultServerNeed] {
        plan.servers + keySwapNeeds.filter { need in !plan.servers.contains { $0.machine == need.machine } }
    }

    /// **The stops that this model holds for one server**, in the words of its steps (`InstallTarget.refusedHostKey`
    /// among them): the trust step's last try, the key swap step's last try (its record, from its first stop on, and
    /// not only its row after six; the words are inside its own sentence, `KeySwapWords.notSwitchedOn`), and for the
    /// hub's own server (`isHub`) the install's and the update's last try. The server's page reads them for the one
    /// step whose way out is on that page, the port (`MachineChecksModel.portStepIsDue`).
    func stops(of machine: String, isHub: Bool) -> [String] {
        let swaps = reading?.fleetID.map { keySwap.record.records(fleet: $0) } ?? [:]
        return Self.stops(of: machine, isHub: isHub, trust: servers, keySwap: swaps, install: install, update: update)
    }

    /// The same, out of the tries and the records given.
    nonisolated static func stops(of machine: String, isHub: Bool, trust: [String: VaultTries],
                                  keySwap: [String: KeySwapRecord], install: VaultTries?, update: VaultTries?) -> [String] {
        let own = [trust[machine]?.reason, keySwap[machine]?.tries?.reason].compactMap { $0 }
        return own + (isHub ? [install?.reason, update?.reason].compactMap { $0 } : [])
    }

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
    /// the facts changed, by its success or by its try, so the rounds end; five is more than one install needs. The two
    /// record files are read once at the start (`RecordKeeper.reread`): a change of this app goes through their one
    /// keeper, and it reads the file itself.
    private func rounds(_ store: FleetStore) async {
        note(removals.reread())
        note(keySwap.reread())
        for _ in 0..<5 {
            guard await read(store) else { return }
            await unpinRemoved(store)
            switch plan.step {
            case .install: await installOwn(store, pressed: false)
            case .recover: await recover(store)
            case .update: await updateOwn(store, pressed: false)
            case .trust(let machines): for machine in machines { await trust(machine, store) }
            case .nothing, .takeOver:
                await keepTCPWindow(store)
                if case .nothing = plan.step {
                    await seedRound(store)
                    await keySwapRound(store)
                    await poolRound(store)
                }
                return
            }
        }
        _ = await read(store)
    }

    /// At most this many pool statements a round (`poolRound`): the rest wait for the next round, which reads the hub's
    /// list again, so one round of a fleet with hundreds of secrets stays short.
    static let poolBatch = 32

    /// **The pool statements that the hub's default owes the central vault** (owner feature `pool_default`, owner API
    /// 1.328), signed under the hood with the owner key (`GrantSigning.pools`): with no step and no question of the
    /// owner's, a secret that the fleet manager may give reaches its agent at the vault's next delivery.
    private func poolRound(_ store: FleetStore) async {
        guard store.hub == hub, store.state?.ui_features?.contains("pool_default") == true,
              let database = store.state?.db, let due = reading?.poolDue, !due.isEmpty else { return }
        _ = await GrantSigning.pools(Array(due.prefix(Self.poolBatch)), store: store, hub: hub, database: database)
    }

    /// One reading and the plan it gives. A failed read keeps the last reading and decides nothing.
    private func read(_ store: FleetStore) async -> Bool {
        guard store.hub == hub, store.isFresh, let database = store.state?.db else { return false }
        // nil is an answer here, a hub without the vault (404); a failed read is not.
        let fresh: VaultReading?
        do { fresh = try await VaultClient().reading(hub: hub, database: database) } catch { return false }
        guard store.hub == hub, store.state?.db == database else { return false }
        if self.database != database {        // another generation starts clean
            install = nil; recovery = nil; otherOwner = false; takeOverProblem = nil
            confirmedRecovery = nil; confirmedPins = [:]; update = nil; updateFor = nil; tcpWindow = nil; tcpWindowFor = nil
            // signedAt stays: a new generation of the hub does not shorten the day of wait after a signature. So do the
            // tries of each server (package 4): a hub that changes its generation at each reading gets one SSH session
            // for each wait, not one each minute, and after a real restore a server whose try failed waits its due time.
        }
        if fresh?.program != updateFor { update = nil }       // the tries were for another release's program
        if let fleet = fresh?.fleetID, let program = fresh?.program,
           let kept = keySwap.record.update(fleet: fleet), kept.program == program, kept.tries.failures > (update?.failures ?? 0) {
            // a start of the app keeps the tries of the update to this program (the design, change 3); so does a read
            // that gives a larger count than this session's, after its record was not known
            update = VaultTries(failures: kept.tries.failures, last: kept.tries.last, reason: kept.tries.reason)
            updateFor = program
        }
        self.database = database
        served = fresh != nil
        reading = fresh
        if let fleet = fresh?.fleetID, !removedHere.isEmpty || !addedHere.isEmpty {
            let (marked, joined) = (removedHere, addedHere)
            changeRemovals { record in
                for (machine, at) in marked { record.removed(machine, fleet: fleet, at: at, unpin: true) }
                for machine in joined { record.added(machine, fleet: fleet) }
            }
            // This Mac's record after the Remove servers and Add servers of this session from before the fleet was known
            // (a machine is in one of the two at most).
            for machine in marked.keys { MacVaultPins.note(.removed, machine: machine, hub: hub, fleet: fleet) }
            for machine in joined { MacVaultPins.note(.added, machine: machine, hub: hub, fleet: fleet) }
            removedHere = [:]; addedHere = []
        }
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
        // The first look of a run at the owner key reads the item and signs once with the chip: off the main actor, so a
        // chip or a token daemon that does not answer stops no window, and one look at a time for each fleet, so the
        // reading of each minute holds no more threads while one waits; `facts` then takes this run's answer.
        if let fleet = fresh?.fleetID { _ = await OwnerKeychain.look(fleet: fleet) }
        plan = VaultPlan.of(fresh, facts: facts)
        return true
    }

    private var facts: VaultFacts {
        let fleet = reading?.fleetID
        var removed = Set(removedHere.keys)
        if let fleet { removed.formUnion(removals.record.marks(fleet: fleet).keys) }
        removed.subtract(addedHere)
        return VaultFacts(keyHeld: fleet.map(OwnerKeychain.isHeld) ?? false,
                          pin: fleet.flatMap { CentralVaultPins.recipient(hub: hub, fleet: $0) }, hubOnRecord: hubOnRecord,
                          otherOwner: otherOwner, keyOtherMac: fleet.map(OwnerKeychain.isOtherMac) ?? false,
                          confirmedRecovery: confirmedRecovery, confirmedPins: confirmedPins, signedAt: signedAt,
                          install: install, recovery: recovery, servers: servers, update: update, removed: removed,
                          removedKnown: removals.known, updateKnown: keySwap.known, now: Date().timeIntervalSince1970)
    }

    // MARK: the servers that the owner removed on this Mac (package 4 of the vault's gates)

    /// Remove server on this Mac, after the hub took it: the mark is written first, and the unpin of that machine goes
    /// in the next round, which this starts at once. The removal never waits for the unpin and never fails because of
    /// it. Before the model has read its fleet, the mark waits in this session and is written at the first reading.
    /// It is the one change that clears this Mac's record of the key that it last signed for that machine
    /// (`MacVaultPins`), so the Add server after it gives the machine a first pin.
    func removed(_ machine: String, store: FleetStore) {
        let at = Date().timeIntervalSince1970
        addedHere.remove(machine)
        if let fleet = reading?.fleetID {
            changeRemovals { $0.removed(machine, fleet: fleet, at: at, unpin: true) }
            MacVaultPins.note(.removed, machine: machine, hub: hub, fleet: fleet)
        } else {
            removedHere[machine] = at
        }
        unpins[machine] = nil; servers[machine] = nil
        tick(store: store, woken: true)
    }

    /// True when the owner removed `machine` on this Mac: also during a step that was on its way when he did.
    private func isRemoved(_ machine: String) -> Bool {
        if addedHere.contains(machine) { return false }
        if removedHere[machine] != nil { return true }
        return reading?.fleetID.map { removals.record.marks(fleet: $0)[machine] != nil } ?? false
    }

    /// Add server for `machine` on this Mac: a server that joined with a join code of this Mac. Its mark goes, so it
    /// gets the trust step of a new server again. The change always goes to the keeper: when the file gives no record
    /// now, it waits, and it takes away a mark that only the file holds; when there is no mark, it writes nothing.
    /// Try again on a server's row runs this first: this Mac's record of the key that it last signed for the machine
    /// stays as it is (`MacVaultPins.Change.added`).
    func added(_ machine: String) {
        removedHere[machine] = nil
        if let fleet = reading?.fleetID {
            let marked = removals.record.marks(fleet: fleet)[machine] != nil
            changeRemovals { $0.added(machine, fleet: fleet) }
            MacVaultPins.note(.added, machine: machine, hub: hub, fleet: fleet)
            guard marked else { return }
        } else {
            addedHere.insert(machine)
        }
        unpins[machine] = nil; servers[machine] = nil       // its first trust starts with no try of the machine before
    }

    /// One change of the record, made to the record as its file holds it now and written back at once. A read that gives
    /// no record, or a write that fails, leaves the change in this Mac's copy, where it waits for a good read
    /// (`RecordKeeper`), so this Mac still signs no pin of a machine that it marked.
    private func changeRemovals(_ change: @escaping (inout VaultRemovals) -> Void) {
        removals.change(change)
    }

    /// The unpin of each machine that the owner removed on this Mac, until the central vault took it: signed with this
    /// Mac's owner key and sent as a pin is (`POST /ui/vault/pin`). One that fails is tried again after
    /// `VaultTries.wait`, for ever, and has no row: the hub can hold an unpin back (VAULT.md limit 8), but this Mac signs
    /// that machine's pin no more, so it ends within 90 days at each broker.
    private func unpinRemoved(_ store: FleetStore) async {
        guard let fleet = reading?.fleetID, reading?.central?.ok == true else { return }
        let now = Date().timeIntervalSince1970
        for machine in removals.record.unpinsDue(fleet: fleet, tries: unpins, now: now) {
            do {
                guard store.hub == hub, store.isFresh, let database = store.state?.db, let key = OwnerKeychain.key(fleet: fleet) else {
                    throw Stop(String(l10n: "Founderizer has no current status of the hub, or no owner key for it."))
                }
                if let problem = clockProblem(store) { throw Stop(problem) }
                let statement = OwnerStatement.unpin(fleet: fleet, machine: machine)
                _ = try await VaultClient().pin(hub: hub, database: database, client: store.installation, statement: statement,
                                                signature: key.sign(statement))
                changeRemovals { $0.unpinned(machine, fleet: fleet) }
                unpins[machine] = nil
            } catch {
                unpins[machine] = VaultTries.failed(after: unpins[machine], at: now, reason: Self.words(error))
            }
        }
    }

    /// The clock guard: why this Mac signs no pin now (`VaultPlan.clockProblem`), against the hub's clock of the store's
    /// last state read.
    private func clockProblem(_ store: FleetStore) -> String? {
        VaultPlan.clockProblem(hubTime: store.state?.time, readAt: store.lastSuccess?.timeIntervalSince1970)
    }

    // MARK: the owner's own presses

    /// Retry on the Founderizer Vault row: the step that gave up, once more now. Another failure keeps the row, with
    /// the new reason; it does not start the automatic tries again.
    func retry(_ store: FleetStore) {
        guard !working, case .retry(let step, _)? = plan.vault else { return }
        run("vault", store) { model in
            switch step {
            case .install: await model.installOwn(store, pressed: true)
            case .recover: await model.recover(store)
            case .update: await model.updateOwn(store, pressed: true)
            default: break
            }
        }
    }

    /// Retry on a server's row: its key read and pinned once more now. On the row of a server that the owner removed on
    /// this Mac, it is the owner's own act on this Mac: the mark goes first, and the trust step runs with each of its checks
    /// (package 4 of the vault's gates). A hub that is broken into can make that row show, but it cannot press the button.
    func retry(server machine: String, _ store: FleetStore) {
        guard !working else { return }
        run(machine, store) { model in
            model.added(machine)
            await model.trust(machine, store)
            if let fleet = model.reading?.fleetID { model.changeKeySwap { $0.tryAgain(server: machine, fleet: fleet) } }
        }
    }

    /// Try again on a server's row that its key swap step gave: its tries and its hold go, and its step runs once now.
    func retryKeySwap(server machine: String, _ store: FleetStore) {
        guard !working, let fleet = reading?.fleetID else { return }
        run(machine, store) { model in
            model.changeKeySwap { $0.tryAgain(server: machine, fleet: fleet) }
            await model.keySwapRound(store, only: machine)
        }
    }

    /// Set up, only where the vault is not this Mac's to act on: the install without the check that a vault there is
    /// this Mac's, so its owner key becomes this Mac's and another Mac's key no longer signs for it.
    func takeOver(_ store: FleetStore) {
        guard !working, case .setUp? = plan.vault else { return }
        takeOverProblem = nil
        run("vault", store) { model in
            switch await model.installed(store, own: false, pressed: true) {
            case .done: model.install = nil; model.otherOwner = false
            case .stopped(let says): model.takeOverProblem = says
            case .otherOwner, .waitsForSetUp: break         // only the app's own install, and only with no press
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

    /// `waitsForSetUp`: an automatic round met another Mac's owner key on this Mac, which only a press replaces; the
    /// next reading's plan shows Set up, with no tries counted.
    private enum Outcome { case done, stopped(String), otherOwner, waitsForSetUp }

    /// A stop of a step, in the owner's words.
    private struct Stop: LocalizedError {
        let says: String
        init(_ says: String) { self.says = says }
        var errorDescription: String? { says }
    }

    /// The app's own install, and its try. `pressed`: the owner's Try again, else an automatic round.
    private func installOwn(_ store: FleetStore, pressed: Bool) async {
        switch await installed(store, own: true, pressed: pressed) {
        case .done: install = nil; otherOwner = false
        case .stopped(let says): install = VaultTries.failed(after: install, at: Date().timeIntervalSince1970, reason: says)
        case .otherOwner: otherOwner = true
        case .waitsForSetUp: break
        }
    }

    /// The vault's update, when it runs another program than the hub's release: the app's own install again
    /// (`--keep-owner`), done only once the hub reads the vault with the release's program. Its tries are for that one
    /// program: the next release's starts them again.
    private func updateOwn(_ store: FleetStore, pressed: Bool) async {
        guard let program = reading?.program else { return }
        let outcome = await installed(store, own: true, program: program, pressed: pressed)
        switch outcome {
        case .waitsForSetUp: return
        case .done: update = nil
        case .stopped(let says):
            update = VaultTries.failed(after: updateFor == program ? update : nil, at: Date().timeIntervalSince1970, reason: says)
        case .otherOwner:
            update = VaultTries.failed(after: updateFor == program ? update : nil, at: Date().timeIntervalSince1970,
                                       reason: String(l10n: "The central vault on the hub's server holds another Mac's owner key."))
        }
        updateFor = program
        if let fleet = reading?.fleetID {
            // Made inside the change, from the tries that the record holds for this program: a change that waits for a
            // good read never puts a smaller count over the file's (`RecordKeeper.change`).
            let tries = update
            changeKeySwap { state in
                guard let tries else { return state.setUpdate(nil, fleet: fleet) }
                let kept = state.update(fleet: fleet).flatMap { $0.program == program ? $0.tries.failures : nil } ?? 0
                state.setUpdate(KeySwapUpdate(program: program, tries: KeySwapTries(failures: max(tries.failures, kept + 1),
                                                                                    last: tries.last, reason: tries.reason)),
                                fleet: fleet)
            }
        }
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
            return try await SSHRun.run(CentralVaultRemote.arguments(target: target, program: program), to: target,
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
        return try await SSHRun.run(CentralVaultRemote.arguments(target: target, program: program), to: target,
                                    timeout: 900)
    }

    // MARK: the key swap's own step (Part B, app patch 2)

    /// **One key swap step at the end of a round** (`KeySwapPlan.next`): on one server, the keys step (the owner keys
    /// and the fleet of the central vault's own file on the hub's server, or the reading alone when that file cannot be
    /// read), and the switch after it when the table wants one and the keys step's answer lets it. Each answer goes into
    /// this Mac's record on the disk at once, and its reading to the hub. `only`: the owner's Try again on that server's
    /// row. Its stops give the rows of the Secrets page (`keySwapNeeds`).
    private func keySwapRound(_ store: FleetStore, only: String? = nil) async {
        guard store.hub == hub, store.isFresh, let database = store.state?.db, database == self.database,
              store.state?.ui_features?.contains(KeySwapPlan.feature) == true, let fleet = reading?.fleetID,
              let rows = try? await KeySwapClient().rows(hub: hub, database: database) else { return }
        let removed = facts.removed
        defer { keySwapNeeds = KeySwapPlan.needs(rows, records: keySwap.record.records(fleet: fleet), removed: removed) }
        var keyFacts = KeySwapFacts(central: keySwapKeys?.central, hubProgram: reading?.program,
                                    records: keySwap.record.records(fleet: fleet), removed: removed, resignDue: resigned,
                                    recordsKnown: keySwap.known, removedKnown: removals.known,
                                    now: Date().timeIntervalSince1970)
        let mine = only.map { name in rows.filter { $0.name == name } } ?? rows
        var next = KeySwapPlan.next(mine, facts: keyFacts)
        let age = keySwapKeys.map { Date().timeIntervalSince($0.at) } ?? .infinity
        // a list that could not be read is read again after `wait` also when no step is due, so one failed read never
        // holds each switch for `keySwapKeysEvery`
        if only != nil || age >= Self.keySwapKeysEvery
            || (age >= KeySwapPlan.wait && (next != nil || keySwapKeys?.central == nil)) {
            let read = await keySwapCentral(database: database)
            keySwapKeys = (read, Date())
            keyFacts.central = read
            next = KeySwapPlan.next(mine, facts: keyFacts)
        }
        let central = keyFacts.central
        guard let step = next, let row = rows.first(where: { $0.name == step.server }) else { return }
        resigned.remove(step.server)
        let keys = await keySwapStep(row, KeySwapRemote.keys(step.keys, fleet: step.fleet), keys: step.keys, fleet: step.fleet,
                                     store: store, database: database, fleetID: fleet)
        if step.gate, keys != nil { await keySwapGate(row, database: database) }
        guard let to = step.then, let keys, KeySwapPlan.switchMayFollow(keys, central: central) else { return }
        _ = await keySwapStep(row, KeySwapRemote.turn(to), keys: step.keys, fleet: step.fleet, store: store,
                              database: database, fleetID: fleet)
    }

    /// **The outgoing gate on the hub's own server** (`KeySwapStep.gate`), after a keys step that reached it: its own
    /// root step, which changes nothing where the gate is on. Its answer keeps no record of the key swap's: a gate that
    /// did not come is the hub's server watch's to say, for a hub's server that takes agents (`egress_troubles`).
    private func keySwapGate(_ row: KeySwapServer, database: String) async {
        // the hub's own machine only by `hubTarget` (VAULT.md, "Who the Mac logs in as, and where")
        guard row.hub, let target = try? await hubTarget(row.name, database: database, record: reading?.hub?.reach)
        else { return }
        _ = try? await SSHRun.run(CentralVaultRemote.arguments(target: target, program: KeySwapRemote.gate), to: target,
                                  timeout: 600)
    }

    /// One root step on one server, its record and its reading to the hub; its answer, or nil when it did not reach
    /// the server. The record is made inside the change, from the server's record that the change is made to, so a
    /// change that waits for a good read keeps that record's hold and tries (`RecordKeeper.change`).
    private func keySwapStep(_ row: KeySwapServer, _ program: String?, keys: [String], fleet: String?, store: FleetStore,
                             database: String, fleetID: String) async -> KeySwapAnswer? {
        let now = Date().timeIntervalSince1970, server = row.name, wish = row.wish
        do {
            guard let program else { throw Stop(String(l10n: "Founderizer cannot write the install for this owner key.")) }
            // The hub's own server only by `hubTarget`, as the central vault's steps (VAULT.md, "Who the Mac logs in as,
            // and where"): the record is the hub's word, and a first label alone could name another node. Each joined
            // server by its own connection, which this Mac's Tailscale names.
            let target: InstallTarget
            if row.hub {
                target = try await hubTarget(row.name, database: database, record: reading?.hub?.reach)
            } else {
                target = try await self.target(row.name, database: database)
                guard await MacNetwork.device(of: target.host) == row.name else {
                    throw Stop(String(l10n: "This Mac's Tailscale does not say that \(target.host) is \(row.name). Founderizer pinned nothing."))
                }
            }
            let output = try await SSHRun.run(CentralVaultRemote.arguments(target: target, program: program), to: target,
                                              timeout: 600)
            if let step = target.refusedHostKey(in: output.lines, server: row.name) { throw Stop(step) }
            let answer = KeySwapAnswer.read(output.output, status: output.status)
            changeKeySwap { state in
                let earlier = state.records(fleet: fleetID)[server]
                state.set(KeySwapPlan.record(answer, after: earlier, wish: wish, keys: keys, fleet: fleet, at: now),
                          server: server, fleet: fleetID)
            }
            await keySwapTell(row, answer: answer, store: store, database: database)
            return answer
        } catch {
            let words = Self.words(error)
            changeKeySwap { state in
                let earlier = state.records(fleet: fleetID)[server]
                state.set(KeySwapPlan.record(stop: words, after: earlier, at: now), server: server, fleet: fleetID)
            }
            return nil
        }
    }

    /// The owner keys and the fleet of the central vault, read as root on the hub's machine from the vault's own file,
    /// or nil: then only the reading runs, and no switch. These keys become owner keys of each server's vault, the trust
    /// of each handover, so the read is bound to the hub's machine by this Mac's own knowledge and not by the hub's pages
    /// (the manager's read of 16 November): this Mac's Tailscale names the connection's host as the hub's machine, and
    /// names the host of this Mac's own hub address as that same machine (`CentralVaultRemote.hubMachineStop`), and
    /// the file's fleet is the fleet that this Mac reads. The install and the update of the central vault check the
    /// same two names since 22 November 2026: the key that they print is the pin.
    private func keySwapCentral(database: String) async -> KeySwapCentral? {
        let machine: String
        if let own = reading?.hub?.machine {
            machine = own
        } else {
            guard let machines = try? await HubClient().machines(hub: hub, database: database).machines else { return nil }
            machine = CentralVault.hubMachine(in: machines)
        }
        guard let fleet = reading?.fleetID,
              let target = try? await hubTarget(machine, database: database, record: reading?.hub?.reach),
              let answer = try? await SSHRun.run(CentralVaultRemote.arguments(target: target,
                                                                              program: KeySwapRemote.central),
                                                 to: target, timeout: 120),
              let central = KeySwapRemote.central(in: answer.output), central.fleet == fleet else { return nil }
        return central
    }

    /// The reading of one step to the hub (`POST /ui/servers/<server>/key-swap-reading`): what a good step read, or the
    /// word as the hub has it with the step's own reason. A put-back says that the vault does not swap. An older program
    /// and a step with no line send nothing: the next step sends. A refused version of team.json is read again once.
    private func keySwapTell(_ row: KeySwapServer, answer: KeySwapAnswer, store: FleetStore, database: String) async {
        let swaps: Bool, reason: String?
        switch answer.outcome {
        case .done(_, let said, _, _): (swaps, reason) = (said, nil)
        case .stopped(let said, let undone): (swaps, reason) = (undone ? false : row.word ?? false, said)
        case .olderProgram, .unread: return
        }
        for _ in 0..<2 {
            guard let sha256 = try? await HubClient().team(hub: hub, database: database).sha256 else { return }
            if (try? await KeySwapClient().reading(hub: hub, database: database, client: store.installation, server: row.name,
                                                   sha256: sha256, swaps: swaps, reason: reason)) != nil { return }
        }
    }

    /// One change of the key swap's records, made to the records as the file holds them now and written back at once. A
    /// read that gives no record, or a write that fails, leaves the change in this Mac's copy, where it waits for a good
    /// read (`RecordKeeper`).
    private func changeKeySwap(_ change: @escaping (inout KeySwapState) -> Void) {
        keySwap.change(change)
    }

    /// A move of a record file in the app's log: the file gave no record at `RecordKeeper.mostUnread` round reads in a
    /// row. The names are the files' own, never a path.
    private func note(_ event: RecordFileEvent?) {
        switch event {
        case .movedAside(let file, let aside)?:
            Self.log.error("\(file, privacy: .public) gave no record at \(RecordKeeper<VaultRemovals>.mostUnread) round reads in a row: it is now \(aside, privacy: .public), and this Mac's copy took its place.")
        case .notMoved(let file, let cause)?:
            Self.log.error("\(file, privacy: .public) gave no record at \(RecordKeeper<VaultRemovals>.mostUnread) round reads in a row, and it could not go to a new name (\(cause, privacy: .public)): this Mac goes on with its copy.")
        case nil:
            break
        }
    }

    /// The install on the hub's machine, from root's own clone there, the pin of the key it printed, and the hub's
    /// reading of that same key. It runs only on the machine that this Mac's own Tailscale names as the hub's, at the
    /// connection's address and at this Mac's hub address (`CentralVaultRemote.hubMachineStop`): until 22 November
    /// 2026 the hub's record alone chose the machine whose root printed the key that became the pin. `own`: the app's
    /// own install, which leaves a vault that another Mac's key holds as it is (`--keep-owner`). `program`: the update
    /// to that program of the hub's release, which is done only when the hub reads the vault running it.
    private func installed(_ store: FleetStore, own: Bool, program release: String? = nil, pressed: Bool) async -> Outcome {
        do {
            guard store.hub == hub, store.isFresh, let database = store.state?.db else {
                throw Stop(String(l10n: "Founderizer has no current status of the hub."))
            }
            guard let reading = try await VaultClient().reading(hub: hub, database: database) else { throw Stop(String(l10n: "This hub has no central vault.")) }
            guard let fleet = reading.fleetID else { throw Stop(String(l10n: "The hub did not say which fleet this is.")) }
            // A new owner key only where the keychain says that none is there, or that it holds one that no chip of
            // this Mac opens (a Mac that Migration Assistant or a restore made from another Mac: the path of a new Mac):
            // a read that fails now (a locked keychain, a chip that does not answer now) stops here and keeps the key,
            // so no passing error gives the hub a new identity (`OwnerKeychain.Lookup`).
            let key: any OwnerKey
            switch OwnerKeychain.lookup(fleet: fleet) {
            case .key(let held): key = held
            case .none: key = try OwnerKeychain.make(fleet: fleet)
            // another Mac's owner key gives way only at the owner's Set up (takeOver, the one install with no
            // --keep-owner): an automatic round (the install where the hub reads no vault, the update after a
            // release) and Try again of the app's own install leave it, and the plan shows Set up. An own install
            // keeps the vault's owner key, so a new key here would match no pin and never show Set up again (the
            // Door area's reads of 25 November 2026)
            case .otherMac where pressed && !own: key = try OwnerKeychain.make(fleet: fleet)
            case .otherMac: return .waitsForSetUp
            case .notNow(let failure): throw Stop(String(l10n: "The keychain refused the key (\(Int(failure.status)))."))
            }
            guard let program = CentralVaultRemote.install(ownerKey: key.publicKey, keepOwner: own) else {
                throw Stop(String(l10n: "Founderizer cannot write the install for this owner key."))
            }
            let machine: String
            if let own = reading.hub?.machine {
                machine = own
            } else {
                machine = CentralVault.hubMachine(in: try await HubClient().machines(hub: hub, database: database).machines)
            }
            // The key that this run prints is the pin: only from the machine that this Mac's own Tailscale names as
            // the hub's, at the connection's address and at this Mac's hub address (`hubTarget`).
            let target = try await hubTarget(machine, database: database, record: reading.hub?.reach)
            let answer = try await SSHRun.run(CentralVaultRemote.arguments(target: target, program: program), to: target, timeout: 900)
            let recipient: String
            switch CentralVaultRemote.installed(answer.output) {
            case .installed(let vaultKey, let printed)?:
                guard printed == fleet else {
                    throw Stop(String(l10n: "The vault on \(machine) belongs to the fleet \(printed), and the hub is \(fleet). Founderizer pinned nothing."))
                }
                recipient = vaultKey
            case .otherOwner?: return .otherOwner
            case .refused(let says)?: throw Stop(String(l10n: "The install on \(machine) stopped: \(says)"))
            case nil: throw Stop(Self.unread(answer, target: target, machine: machine, what: String(l10n: "the install's answer")))
            }
            // The key the machine printed is the pin. Nothing is sealed to the vault before the hub names that same key.
            // An update, and the app's own install, never move a pin that this Mac holds (`CentralVaultPins.refusal`).
            if let refused = CentralVaultPins.refusal(of: recipient, held: CentralVaultPins.recipient(hub: hub, fleet: fleet),
                                                      setUp: !own) {
                throw Stop(refused)
            }
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
    /// (by the hub's word and this Mac's Tailscale both, `trustTarget`) is Founderizer Vault's own `status`, asked as the
    /// user it serves, with no `sudo` (DevOps plan V4). A Mac server whose key this Mac signed before gets no other key
    /// (`MacVaultPin`, VAULT.md limit 10): the guard asks before the read and again with the read key, and the record
    /// takes each key that it signs.
    private func trust(_ name: String, _ store: FleetStore) async {
        do {
            guard store.hub == hub, store.isFresh, let database = store.state?.db, let fleet = reading?.fleetID,
                  let key = OwnerKeychain.key(fleet: fleet) else {
                throw Stop(String(l10n: "Founderizer has no current status of the hub, or no owner key for it."))
            }
            guard let machine = reading?.machines.first(where: { $0.machine == name }), let reported = machine.broker_recipient,
                  machine.canBeTrusted else { throw Stop(String(l10n: "The hub reports no vault key for \(name) now.")) }
            // The owner removed it on this Mac after this round's plan was made: no SSH session, and no pin.
            if isRemoved(name) { servers[name] = nil; return }
            if let problem = clockProblem(store) { throw Stop(problem) }
            let kind = try await HubClient().servers(hub: hub, database: database).servers.first(where: { $0.name == name })?.kind
            let (target, mac, os) = try await trustTarget(name, kind: kind, database: database)
            // A Mac server whose key this Mac signed before gets no other key: another bound key stops here, with no SSH
            // session, and another read key after the read (`MacVaultPin`, VAULT.md limit 10).
            let otherKey = String(l10n: "The vault key on \(name) is not the one the hub reports for it. Founderizer pinned nothing.")
            let guarded = MacVaultPin(kind: kind, os: os, record: MacVaultPins.records(hub: hub, fleet: fleet)[name])
            guard guarded.mayRead(bound: reported) else { throw Stop(otherKey) }
            let program = mac ? CentralVaultRemote.readMacVaultKey : CentralVaultRemote.readBrokerKey
            let answer = try await SSHRun.run(CentralVaultRemote.arguments(target: target, program: program), to: target,
                                              timeout: 120)
            guard let found = CentralVaultRemote.brokerKey(in: answer.output) else {
                throw Stop(Self.unread(answer, target: target, machine: name, what: String(l10n: "its vault key")))
            }
            guard let signed = guarded.signs(found: found, bound: reported) else { throw Stop(otherKey) }
            // The owner removed it on this Mac while its key was read: it gets no pin (package 4 of the vault's gates).
            if isRemoved(name) { servers[name] = nil; return }
            let statement = OwnerStatement.pin(fleet: fleet, machine: name, recipient: signed)
            let signature = try key.sign(statement)
            // The record takes the key before the signature leaves this Mac: a hub that refuses the pin has it all the same.
            if guarded.keeps { MacVaultPins.note(.signed(signed), machine: name, hub: hub, fleet: fleet) }
            _ = try await VaultClient().pin(hub: hub, database: database, client: store.installation, statement: statement,
                                            signature: signature)
            confirmedPins[name] = signed
            signedAt[name] = Date().timeIntervalSince1970
            servers[name] = nil
            resigned.insert(name)           // the key swap step reads that server's vault again
        } catch {
            servers[name] = VaultTries.failed(after: servers[name], at: Date().timeIntervalSince1970, reason: Self.words(error))
        }
    }

    /// **How this Mac reaches the hub's machine for a step that reads the central vault as root** (its install, its
    /// update, the key swap's read of its owner keys): `target`, and only when this Mac's own Tailscale names that
    /// connection's host and this Mac's hub address as one node (`CentralVaultRemote.hubMachineStop`); else it stops
    /// with those words and nothing runs. `status`: this Mac's `tailscale status --json`, which only a test gives.
    func hubTarget(_ machine: String, database: String, record: MachineReach?,
                   status: () async -> String? = { await MacNetwork.status() }) async throws -> InstallTarget {
        let target = try await self.target(machine, database: database, record: record)
        if let stop = CentralVaultRemote.hubMachineStop(target: target, hub: hub, machine: machine, status: await status()) {
            throw Stop(stop)
        }
        return target
    }

    /// **How this Mac reaches one server for the trust step, and whether it reads that server as a Mac** (R2-M1 of the
    /// validation of 23 November 2026): `trustPeer`, then `trustReach`, from one read of this Mac's Tailscale status.
    /// `os` is that node's Tailscale `OS`, which the Mac server pin's guard takes too (`MacVaultPin`). `record` and
    /// `status`: only a test gives them.
    func trustTarget(_ name: String, kind: String?, database: String, record: MachineReach? = nil,
                     status: () async -> String? = { await MacNetwork.status() }) async throws
        -> (target: InstallTarget, mac: Bool, os: Set<String>) {
        let peer = try await trustPeer(name, database: database, record: record, status: status)
        let (target, mac) = try trustReach(name, kind: kind, peer: peer)
        return (target, mac, peer.os)
    }

    /// The trust step's connection to one server: the one that this Mac keeps, else the fleet's record, at an address
    /// that this Mac's own Tailscale names as that server, with that node's Tailscale `OS`. Else it stops, and no SSH
    /// session opens.
    func trustPeer(_ name: String, database: String, record: MachineReach? = nil,
                   status: () async -> String? = { await MacNetwork.status() }) async throws
        -> (target: InstallTarget, os: Set<String>) {
        let target = try await self.target(name, database: database, record: record, rootOnly: false)
        let peer = MacNetwork.peer(of: target.host, in: await status() ?? "")
        guard peer?.name == name else {
            throw Stop(String(l10n: "This Mac's Tailscale does not say that \(target.host) is \(name). Founderizer pinned nothing."))
        }
        return (target, peer?.os ?? [])
    }

    /// `CentralVaultRemote.trustRead` with the hub's `kind` and the node's `OS`: a Mac by both words is read as the
    /// connection's user, with no `sudo`; each other server as root, with no record's user that is not root.
    func trustReach(_ name: String, kind: String?, peer: (target: InstallTarget, os: Set<String>)) throws
        -> (target: InstallTarget, mac: Bool) {
        var target = peer.target
        guard let read = CentralVaultRemote.trustRead(kind: kind, os: peer.os, user: target.user,
                                                      kept: InstallTargets.target(machine: name, hub: hub) != nil) else {
            throw Stop(String(l10n: "The fleet has no SSH connection to \(name) on record. Record one on its page in Servers."))
        }
        if read == .agents { target.becomeRoot = false; target.macServer = true }
        return (target, read == .agents)
    }

    /// **The first run's seed of this Mac's record** (`MacVaultPin.seed`): the Mac servers that this Mac pinned before it
    /// kept a record get one read each, which signs nothing, so that the guard covers them at once and not only after
    /// their next re-sign. The record takes the read key only when it is the hub's pin and the hub's bound key too. A
    /// Linux server gets no SSH session. A read that fails is tried again after `VaultTries.wait`, at most
    /// `VaultTries.most` times in a row in one run of the app, with no row.
    private func seedRound(_ store: FleetStore) async {
        guard store.hub == hub, store.isFresh, let database = store.state?.db, database == self.database,
              let reading, let fleet = reading.fleetID else { return }
        let due = MacVaultPin.seedsDue(reading, records: MacVaultPins.records(hub: hub, fleet: fleet), removed: facts.removed,
                                       removedKnown: removals.known, tries: seeds, now: Date().timeIntervalSince1970)
        guard !due.isEmpty, let servers = try? await HubClient().servers(hub: hub, database: database).servers else { return }
        for name in due {
            await seed(name, kind: servers.first(where: { $0.name == name })?.kind, database: database, fleet: fleet)
        }
    }

    private func seed(_ name: String, kind: String?, database: String, fleet: String) async {
        do {
            guard let machine = reading?.machines.first(where: { $0.machine == name }), !isRemoved(name) else {
                seeds[name] = MacVaultPin.seedEnded(at: Date().timeIntervalSince1970)
                return
            }
            let peer = try await trustPeer(name, database: database)
            guard MacVaultPin(kind: kind, os: peer.os, record: nil).covered else {
                seeds[name] = MacVaultPin.seedEnded(at: Date().timeIntervalSince1970)
                return
            }
            let (target, mac) = try trustReach(name, kind: kind, peer: peer)
            let program = mac ? CentralVaultRemote.readMacVaultKey : CentralVaultRemote.readBrokerKey
            let answer = try await SSHRun.run(CentralVaultRemote.arguments(target: target, program: program), to: target,
                                              timeout: 120)
            guard let found = CentralVaultRemote.brokerKey(in: answer.output) else {
                throw Stop(Self.unread(answer, target: target, machine: name, what: String(l10n: "its vault key")))
            }
            if !isRemoved(name),
               let kept = MacVaultPin.seed(record: MacVaultPins.records(hub: hub, fleet: fleet)[name], pinned: machine.pinned,
                                           bound: machine.broker_recipient, found: found) {
                MacVaultPins.note(.seeded(kept), machine: name, hub: hub, fleet: fleet)
            }
            seeds[name] = MacVaultPin.seedEnded(at: Date().timeIntervalSince1970)
        } catch {
            seeds[name] = VaultTries.failed(after: seeds[name], at: Date().timeIntervalSince1970, reason: Self.words(error))
        }
    }

    /// How this Mac reaches one machine: the connection it keeps for it, else the fleet's own record of it. A kept user
    /// who is not root becomes root with `sudo -n`, so nothing waits for a password. **A record's user other than root is
    /// no connection of a root step** (`rootOnly`; the validation of 23 November 2026, M1): that user owns its
    /// `~/.ssh/authorized_keys`, so a forced command there prints what it likes for the whole session, the `sudo` and
    /// root's read included, and `hub.sh` records the hub's own user, `fleet`, for its server. Such a record stops the
    /// step with the words of no record, whose way out (the server's page) gives a connection of the owner's. The trust
    /// read of a Mac's vault, as the agents' user, keeps its own rule (`rootOnly` false; limit 10 of VAULT.md).
    private func target(_ machine: String, database: String, record: MachineReach? = nil,
                        rootOnly: Bool = true) async throws -> InstallTarget {
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
        guard let known = fleets?.onRecord, known.user == "root" || !rootOnly else {
            throw Stop(String(l10n: "The fleet has no SSH connection to \(machine) on record. Record one on its page in Servers."))
        }
        let target = InstallTarget(host: known.address, user: known.user, port: known.port, becomeRoot: known.user != "root")
        guard target.isValid else { throw Stop(target.problem ?? String(l10n: "The fleet's record of \(machine) is not a connection.")) }
        return target
    }

    /// What an answer over SSH says when it lacks the line Founderizer reads: the owner's step for a host key that `ssh`
    /// refused (the vault's steps check it strictly; `InstallTarget.refusedHostKey`), or the machine's own last line.
    private static func unread(_ answer: LocalShell.Answer, target: InstallTarget, machine: String, what: String) -> String {
        if let step = target.refusedHostKey(in: answer.lines, server: machine) { return step }
        // Plain words only (T-35): the machine's own last line was appended to this one.
        return String(l10n: "Founderizer could not read \(what) on \(machine).")
    }

    private static func words(_ error: Error) -> String {
        HubError.said(error) ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

}

/// **The vault's two record files on this Mac, with one keeper each for the whole app** (`RecordKeeper`): the model of
/// each hub address reads and changes the same files, so they share one copy, one list of changes that wait and one
/// count of reads that gave no record. Each keeper makes its first read when a model first uses it.
@MainActor
enum VaultRecordFiles {
    static var removals = RecordKeeper(file: VaultRemovals.file, empty: VaultRemovals())
    static var keySwap = RecordKeeper(file: KeySwapState.file, empty: KeySwapState())
}

/// **The top of the Secrets page, only while the central vault needs the owner**: the Founderizer Vault row when an
/// automatic step gave up (its "!" and Retry; the update too, after six tries) or when the vault is not this Mac's to
/// act on (Set up), and one row for each server that the automatic trust or the key swap's step gave up on (its "!" and
/// Retry; a put-back of the key swap at once). With everything in order there is no row at all.
struct CentralVaultSection: View {
    @Bindable var store: FleetStore
    @Bindable var model: CentralVaultModel

    var body: some View {
        if model.plan.vault != nil || !model.serverRows.isEmpty {
            FormSection {
                if let need = model.plan.vault {
                    FormRow("Founderizer Vault", symbol: "lock.shield") { vaultControl(need) }
                        .accessibilityIdentifier("vault-row")
                }
                ForEach(model.serverRows) { server in
                    let trust = model.plan.servers.contains { $0.machine == server.machine }
                    FormRow(server.machine, symbol: "server.rack") {
                        control(row: server.machine, reason: server.reason, words: String(l10n: "Try again")) {
                            if trust { model.retry(server: server.machine, store) } else { model.retryKeySwap(server: server.machine, store) }
                        }
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
                Button(words, action: action).buttonStyle(FleetOutlineButtonStyle()).disabled(!store.writesNow || model.working)
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
