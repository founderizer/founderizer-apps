import Foundation

/// **What this Mac does about the fleet's central vault now**, decided from the hub's reading (`GET /ui/vault`) and
/// from what this Mac knows itself.
///
/// The owner, 24 October 2026, on the Set up button: "this should be automatically setup, even under the hood if we
/// dont need anything!" So the app installs the vault, gives it a recovery key and trusts each server by itself, and
/// the Secrets page has a row only where he is the one who can move things: an automatic step that gave up, or a
/// vault that this Mac does not hold. It is one pure function, so that everything the app does without asking is
/// written in one place and tested there.
///
/// It also brings the vault's program up to date with the hub's release (`update`), with the root step of the
/// install, as a machine's server service does for its broker: the owner, 6 November 2026, "Nothing needs to be done
/// by hand!". After six tries of that step in a row, the Founderizer Vault row shows its reason, and the step is
/// tried again each hour (Part B of the key swap, app patch 2, with the owner's yes to its sentence, C47).
///
/// Three rules bound it. A step that fails waits 10 minutes and is tried again, at most 6 times in a row, and then
/// waits for the owner (a re-sign of a kept pin shows its row then, and goes on each hour). The install runs only while the hub reads no central vault and the fleet has an SSH
/// connection on record for the hub's own machine. And **a second Mac never takes the vault over by itself**: when
/// the vault answers but this Mac holds no owner key or no pin of the vault's key, or its pin is not the key the hub
/// names, nothing runs and only the owner's own Set up can act, because that install takes the vault's owner key from
/// whichever Mac holds it now.
public struct VaultPlan: Equatable, Sendable {
    /// This Mac signs the pin of each trusted machine again when the one that the hub keeps is 7 days old, or when the
    /// hub keeps none (a machine pinned before the hub kept pins), so that the hub always holds a fresh pin of each
    /// trusted machine for its handovers (`hub.py` `handover_key`).
    public static let pinRefresh: Double = 7 * 86400
    /// After a re-sign that succeeded, the next one of that machine waits a day, also when the hub's reading does not
    /// show it yet: a hub that never shows `kept_pin_at` gets one signature a day, not one every ten minutes.
    public static let resignWait: Double = 86400
    /// A re-sign never gives up: after its sixth failure in a row its server row shows, and it is tried again each hour.
    /// The first trust of a server keeps its own rule: six tries, then the owner's Retry.
    public static let retryEvery: Double = 3600
    /// This Mac signs no pin while its clock and the hub's clock differ by more than this: its pins would be dated ahead
    /// of each broker's clock, or be old at once (package 4, the clock guard).
    public static let clockSkew: Double = 3600
    static let clockWords = String(l10n: "This Mac's clock and the hub's clock differ by more than an hour.")

    /// Why this Mac signs no pin now, or nil: its clock and the hub's clock of its last state read (`hubTime`, read at
    /// this Mac's `readAt`) differ by more than `clockSkew`. Each due machine counts it as a failed try, and after six the
    /// server's row shows it; the pin is signed at its next try once the clocks agree.
    public static func clockProblem(hubTime: Double?, readAt: Double?) -> String? {
        guard let hubTime, let readAt else { return nil }
        return abs(hubTime - readAt) > clockSkew ? clockWords : nil
    }

    public let step: VaultStep
    /// The Founderizer Vault row, when the vault itself needs the owner.
    public let vault: VaultNeed?
    /// The servers the automatic trust gave up on, and the servers that the owner removed on this Mac and the hub names
    /// again, in the hub's order.
    public let servers: [VaultServerNeed]

    public init(step: VaultStep, vault: VaultNeed? = nil, servers: [VaultServerNeed] = []) {
        self.step = step; self.vault = vault; self.servers = servers
    }

    public static let none = VaultPlan(step: .nothing)
    static let otherKey = String(l10n: "The hub names another vault key than the one this Mac pinned.")
    static let otherOwner = String(l10n: "The central vault on the hub's server holds another Mac's owner key.")
    static let removedHere = String(l10n: "You removed this server on this Mac, so Founderizer does not trust its vault by itself. Select Try again to trust it.")

    public static func of(_ reading: VaultReading?, facts: VaultFacts) -> VaultPlan {
        guard let reading, reading.fleetID != nil else { return .none }         // no vault served, or no fleet named
        guard let central = reading.central else {
            // The hub reads no vault: none was installed, or it is down. Only the app's own install runs, from root's
            // own clone on the hub's machine, and it leaves a vault that another Mac's key holds as it is
            // (`CentralVaultRemote.install(ownerKey:keepOwner: true)`).
            if facts.otherOwner { return VaultPlan(step: .takeOver, vault: .setUp(otherOwner)) }
            // another Mac's owner key on this Mac: no automatic install puts a new one in its place, only Set up (the
            // Door area's read of 25 November 2026)
            if facts.keyOtherMac { return VaultPlan(step: .takeOver, vault: .setUp(nil)) }
            if let tries = facts.install, tries.givenUp { return VaultPlan(step: .nothing, vault: .retry(.install, tries.reason)) }
            guard facts.hubOnRecord, facts.install?.isDue(at: facts.now) ?? true else { return .none }
            return VaultPlan(step: .install)
        }
        guard central.ok, let recipient = central.recipient else { return .none }
        guard facts.keyHeld, let pin = facts.pin else { return VaultPlan(step: .takeOver, vault: .setUp(nil)) }
        guard pin == recipient else { return VaultPlan(step: .takeOver, vault: .setUp(otherKey)) }
        // Each server whose vault key is not pinned as it reports it now, unless this session's own pin of that very
        // key is still on its way into the hub's next reading (the hub reads the vault's status once a minute). A
        // server that the owner removed on this Mac gets no pin again, whatever the hub's reading says (`VaultRemovals`).
        // While that record is not known, the plan gives no server a pin (`removedKnown`).
        let open = reading.machines.filter {
            facts.removedKnown && $0.canBeTrusted && !$0.isTrusted && !facts.removed.contains($0.machine)
                && facts.confirmedPins[$0.machine] != $0.broker_recipient
        }
        // Each trusted server whose kept pin is missing or `pinRefresh` old, from a hub that says when its kept pin was
        // signed: its key is read and signed again, by the same step, at most once a day after a success. Never a server
        // that the owner removed on this Mac.
        let stale = reading.machines.filter { machine in
            facts.removedKnown && machine.isTrusted && machine.keptPinKnown && !facts.removed.contains(machine.machine)
                && (machine.kept_pin_at.map { facts.now - Double($0) > Self.pinRefresh } ?? true)
                && facts.now - (facts.signedAt[machine.machine] ?? 0) >= Self.resignWait
        }
        let opened = Set(open.map(\.machine)), resigned = Set(stale.map(\.machine))
        // Both kinds in the hub's order, as `servers` says.
        let listed = reading.machines.filter { opened.contains($0.machine) || resigned.contains($0.machine) }
        let gaveUp = listed.compactMap { machine in
            facts.servers[machine.machine].flatMap { $0.givenUp ? VaultServerNeed(machine: machine.machine, reason: $0.reason) : nil }
        }
        // A server that the owner removed on this Mac and that the hub names again as one that can be trusted (another
        // Mac or the owner's MCP tool added it again): its row, with its own reason, and never a step by itself. Try
        // again on that row is the owner's own act on this Mac, which clears the mark (`CentralVaultModel.retry`). The
        // rows in the hub's order.
        let marked = Set(reading.machines.filter { $0.canBeTrusted && facts.removed.contains($0.machine) }.map(\.machine))
        let rows = reading.machines.compactMap { machine -> VaultServerNeed? in
            marked.contains(machine.machine) ? VaultServerNeed(machine: machine.machine, reason: Self.removedHere)
                : gaveUp.first { $0.machine == machine.machine }
        }
        let due = listed.filter { machine in
            guard let tries = facts.servers[machine.machine] else { return true }
            return tries.isDue(at: facts.now)
                || (resigned.contains(machine.machine) && !opened.contains(machine.machine) && tries.givenUp
                    && facts.now - tries.last >= Self.retryEvery)
        }.map(\.machine)
        var vault: VaultNeed?
        if central.recovery == nil && facts.confirmedRecovery == nil {
            if let tries = facts.recovery, tries.givenUp { vault = .retry(.recover, tries.reason) }
            else if facts.recovery?.isDue(at: facts.now) ?? true { return VaultPlan(step: .recover, servers: rows) }
        }
        // The vault runs another program than the hub's release: the install's root step again brings it up to date.
        // After six tries in a row the row shows, and the step goes on each hour (C3). While the record of those tries is
        // not known, the update waits (`updateKnown`).
        if facts.updateKnown, reading.programBehind, let tries = facts.update, tries.givenUp {
            let row = VaultNeed.retry(.update, KeySwapWords.centralBehind(tries.reason))
            if facts.now - tries.last >= Self.retryEvery { return VaultPlan(step: .update, vault: vault ?? row, servers: rows) }
            vault = vault ?? row
        } else if facts.updateKnown, reading.programBehind, facts.update?.isDue(at: facts.now) ?? true {
            return VaultPlan(step: .update, vault: vault, servers: rows)
        }
        return VaultPlan(step: due.isEmpty ? .nothing : .trust(due), vault: vault, servers: rows)
    }
}

/// One step of the plan.
public enum VaultStep: Equatable, Sendable {
    case nothing
    /// The install of the central vault, as root on the hub's machine over this Mac's SSH connection, with this Mac's
    /// owner key, then the pin of the vault's key that it printed and the hub's reading of that same key.
    case install
    /// A recovery code made and kept in this Mac's keychain, and its key signed and sent to the vault.
    case recover
    /// The install's root step again, with `--keep-owner`, because the vault runs another program than the hub's
    /// release: it keeps the vault's keys, its store and the owner's statements, and it has no row.
    case update
    /// These servers' vault keys read over SSH, and each one pinned when it is the key the hub reports: a server not
    /// pinned yet, or one whose pin the hub keeps no more or keeps from `pinRefresh` ago.
    case trust([String])
    /// Nothing runs: the vault is not this Mac's to act on, and only the owner's Set up takes it over.
    case takeOver
}

/// The Founderizer Vault row of the Secrets page.
public enum VaultNeed: Equatable, Sendable {
    /// An automatic step gave up: the step that Retry runs once more, and the reason of its last try.
    case retry(VaultStep, String)
    /// Set up takes the vault over on this Mac and makes its key the vault's owner key; with a reason when there is
    /// more to say than that this Mac does not hold the vault.
    case setUp(String?)
}

/// A server row of the Secrets page: the automatic trust gave up on it.
public struct VaultServerNeed: Equatable, Sendable, Identifiable {
    public let machine: String
    public let reason: String
    public var id: String { machine }
    public init(machine: String, reason: String) { self.machine = machine; self.reason = reason }
}

/// The tries of one automatic step: how many failed in a row, when the last one did, and why.
public struct VaultTries: Equatable, Sendable {
    /// A step that failed is tried again after 10 minutes, at most 6 times in a row.
    public static let wait: Double = 600
    public static let most = 6

    public let failures: Int
    public let last: Double
    public let reason: String

    public init(failures: Int, last: Double, reason: String) { self.failures = failures; self.last = last; self.reason = reason }

    /// The step failed `most` times in a row, so it waits for the owner's Retry.
    public var givenUp: Bool { failures >= Self.most }

    public func isDue(at now: Double) -> Bool { !givenUp && now - last >= Self.wait }

    /// One more failure, after the ones before it.
    public static func failed(after earlier: VaultTries?, at now: Double, reason: String) -> VaultTries {
        VaultTries(failures: (earlier?.failures ?? 0) + 1, last: now, reason: reason)
    }
}

/// What this Mac knows itself, beside the hub's reading.
public struct VaultFacts: Equatable, Sendable {
    /// This Mac holds an owner key for the reading's fleet.
    public var keyHeld: Bool
    /// This Mac's pin of the vault's key: what the install printed on the hub's machine, not what the hub says.
    public var pin: String?
    /// The fleet has an SSH connection on record for the hub's own machine.
    public var hubOnRecord: Bool
    /// The app's own install found the vault on the hub's machine held by another Mac's owner key.
    public var otherOwner: Bool
    /// This Mac holds for the fleet an owner key that no chip of this Mac opens (`OwnerKeychain.Lookup.otherMac`): a
    /// Mac that Migration Assistant or a restore made. Only the owner's Set up replaces it.
    public var keyOtherMac: Bool
    /// What the vault confirmed in this session, which the hub's reading can show up to a minute later.
    public var confirmedRecovery: String?
    public var confirmedPins: [String: String]
    /// When this session last signed a pin of each machine: the hub's reading of it can come up to a minute later.
    public var signedAt: [String: Double]
    public var install: VaultTries?
    public var recovery: VaultTries?
    public var servers: [String: VaultTries]
    /// The tries of the update to the program the hub names now: the next release's program starts them again.
    public var update: VaultTries?
    /// The machines of this fleet that the owner removed on this Mac (`VaultRemovals`): none of them gets a pin.
    public var removed: Set<String>
    /// The record of the removed servers is known (`RecordKeeper.known`). While it is not, the file is there and gives
    /// no record, so the machines that it names are not known: the plan gives no machine a pin. The owner's own Try
    /// again on a server's row is his act on this Mac, and it trusts that server all the same.
    public var removedKnown: Bool
    /// The record that keeps the update's tries is known (`KeySwapState`, `RecordKeeper.known`). While it is not, those
    /// tries are not known, so the update waits.
    public var updateKnown: Bool
    public var now: Double

    public init(keyHeld: Bool, pin: String?, hubOnRecord: Bool, otherOwner: Bool = false, keyOtherMac: Bool = false,
                confirmedRecovery: String? = nil,
                confirmedPins: [String: String] = [:], signedAt: [String: Double] = [:], install: VaultTries? = nil,
                recovery: VaultTries? = nil, servers: [String: VaultTries] = [:], update: VaultTries? = nil,
                removed: Set<String> = [], removedKnown: Bool = true, updateKnown: Bool = true, now: Double) {
        self.keyHeld = keyHeld; self.pin = pin; self.hubOnRecord = hubOnRecord; self.otherOwner = otherOwner
        self.keyOtherMac = keyOtherMac
        self.confirmedRecovery = confirmedRecovery; self.confirmedPins = confirmedPins; self.signedAt = signedAt
        self.install = install; self.recovery = recovery; self.servers = servers; self.update = update
        self.removed = removed; self.removedKnown = removedKnown; self.updateKnown = updateKnown; self.now = now
    }
}
