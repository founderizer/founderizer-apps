import Foundation
import Testing
@testable import FleetCore

/// **This Mac's guard of a Mac server's pin** (`MacVaultPin`, `MacVaultPins`; VAULT.md limit 10). Until root on a Mac
/// server signs its vault key, the key that the owner's Mac reads there and the hub's bound key can both be the words of
/// a hub that is broken into and one agent of that Mac. So this Mac signs a Mac server that it pinned before only with
/// the key of its own record.
struct MacVaultPinTests {
    /// The key that this Mac signed for the Mac server before.
    static let earlier = CentralVaultTests.recipient
    /// A key that a hub that is broken into binds, and that one agent of that Mac answers.
    static let agents = CentralVaultPlanTests.vaultKey
    static let fleet = CentralVaultTests.fleet

    /// Bug: "the pin" is the hub's word, so a hub that is broken into binds another key, one agent of that Mac answers
    /// with it, and the owner's Mac moves that Mac's pin to the agent's key (path E); or the rule follows the hub's kind,
    /// so a hub that names that Mac Linux takes the guard away.
    @Test func aMacServerThatThisMacPinnedGetsNoOtherKey() {
        let words: [(String?, Set<String>)] = [("mac", []), ("linux", ["macOS"]), (nil, ["macOS"]), ("linux", ["linux"])]
        for (kind, os) in words {
            let guarded = MacVaultPin(kind: kind, os: os, record: Self.earlier)
            let said = "\(kind ?? "no kind"), \(os.sorted())"
            #expect(guarded.covered && !guarded.mayRead(bound: Self.agents), "\(said): no SSH session")
            #expect(guarded.signs(found: Self.agents, bound: Self.agents) == nil, "\(said)")
            #expect(guarded.signs(found: Self.agents, bound: Self.earlier) == nil, "\(said): the read alone")
            #expect(guarded.signs(found: Self.earlier, bound: Self.agents) == nil, "\(said): the hub alone")
            #expect(guarded.mayRead(bound: Self.earlier) && guarded.signs(found: Self.earlier, bound: Self.earlier) == Self.earlier,
                    "\(said): the record's key, read and bound, is signed again")
        }
        // With no record yet, a server that the hub names Linux and this Mac's Tailscale names macOS is a Mac server.
        #expect(MacVaultPin(kind: "linux", os: ["macOS"], record: nil).keeps)
    }

    /// Try again on a server's row runs Add server's change first (`CentralVaultModel.retry(server:)`), then the trust
    /// step. Bug: Try again clears the record (round 2 of the design said so), so a hub that is broken into makes the
    /// row show and the owner's natural press pins the agent's key; or Try again can never pass; or a new Mac server
    /// gets no first pin, or its record is never written; or Remove server and then Add server leave the old key, so a
    /// server that the owner set up again stays at a stop.
    @Test func tryAgainKeepsTheRecordAndRemoveServerThenAddServerClearsIt() throws {
        let defaults = TestDefaults("mac-vault-pin-tests")
        let hub = try HubClient.address("http://100.80.1.2:8765"), other = try HubClient.address("http://100.80.1.3:8765")
        func record() -> String? { MacVaultPins.records(hub: hub, fleet: Self.fleet, in: defaults)["mac-studio"] }
        func note(_ change: MacVaultPins.Change) {
            MacVaultPins.note(change, machine: "mac-studio", hub: hub, fleet: Self.fleet, in: defaults)
        }
        /// The trust step of one Mac server, as the model takes it: the guard before the read and with the read key,
        /// and the record of the key that it signs.
        func trust(bound: String, found: String) -> String? {
            let guarded = MacVaultPin(kind: "mac", os: ["macOS"], record: record())
            guard guarded.mayRead(bound: bound), let signed = guarded.signs(found: found, bound: bound) else { return nil }
            if guarded.keeps { note(.signed(signed)) }
            return signed
        }
        func tryAgain(bound: String, found: String) -> String? {
            note(.added)
            return trust(bound: bound, found: found)
        }
        // A first pin, with no record: as before, and the record takes the key that this Mac signed.
        #expect(record() == nil)
        #expect(trust(bound: Self.earlier, found: Self.earlier) == Self.earlier)
        #expect(record() == Self.earlier)
        // The hub binds the agent's key and the agent answers it: each Try again stops, and the record stays.
        for press in 1...3 {
            #expect(tryAgain(bound: Self.agents, found: Self.agents) == nil, "press \(press)")
            #expect(record() == Self.earlier, "press \(press)")
        }
        // Once the hub binds the record's key again, Try again pins it.
        #expect(tryAgain(bound: Self.earlier, found: Self.earlier) == Self.earlier)
        // Remove server on this Mac clears the record, and the Add server after it gives a first pin, of the new key.
        note(.removed)
        #expect(record() == nil)
        #expect(tryAgain(bound: Self.agents, found: Self.agents) == Self.agents)
        #expect(record() == Self.agents)
        // The record is this hub address's and this fleet's.
        #expect(MacVaultPins.records(hub: other, fleet: Self.fleet, in: defaults).isEmpty)
        #expect(MacVaultPins.records(hub: hub, fleet: "0000000000000000", in: defaults).isEmpty)
    }

    /// Bug: the record starts empty, so a Mac server that this Mac pinned before has no guard until its next re-sign,
    /// up to seven days later, because `VaultPlan` gives a trusted server with a fresh pin no step; or the read key is
    /// not in the seed's condition, so a hub that is broken into at that first run names its own key as the pin and as
    /// the bound key, and the record takes it.
    @Test func theFirstRunReadsEachTrustedServerAndKeepsOnlyAKeyThatAllThreeName() throws {
        let (earlier, agents) = (Self.earlier, Self.agents)
        #expect(MacVaultPin.seed(record: nil, pinned: earlier, bound: earlier, found: earlier) == earlier)
        #expect(MacVaultPin.seed(record: nil, pinned: agents, bound: agents, found: earlier) == nil)     // the hub alone
        #expect(MacVaultPin.seed(record: nil, pinned: earlier, bound: agents, found: agents) == nil)
        #expect(MacVaultPin.seed(record: nil, pinned: nil, bound: earlier, found: earlier) == nil)
        #expect(MacVaultPin.seed(record: nil, pinned: earlier, bound: earlier, found: nil) == nil)
        #expect(MacVaultPin.seed(record: agents, pinned: earlier, bound: earlier, found: earlier) == nil)
        // vps is trusted and its pin is not due again: the plan gives it no step, and the seed reads it.
        let recovered = try CentralVaultPlanTests.reading(central: CentralVaultPlanTests.vaultKey, recovery: true)
        let now = CentralVaultPlanTests.now
        #expect(VaultPlan.of(recovered, facts: CentralVaultPlanTests.mine(confirmedPins: ["worker4": CentralVaultPlanTests.serverKey,
                                                                                          "newbox": CentralVaultPlanTests.serverKey])) == .none)
        func due(records: [String: String] = [:], removed: Set<String> = [], known: Bool = true,
                 tries: [String: VaultTries] = [:], at time: Double = now) -> [String] {
            MacVaultPin.seedsDue(recovered, records: records, removed: removed, removedKnown: known, tries: tries, now: time)
        }
        #expect(due() == ["vps"])
        #expect(due(records: ["vps": earlier]).isEmpty)
        #expect(due(removed: ["vps"]).isEmpty)
        #expect(due(known: false).isEmpty)
        #expect(due(tries: ["vps": MacVaultPin.seedEnded(at: now - 86_400)]).isEmpty)       // one seed in a run
        let failed = VaultTries.failed(after: nil, at: now - 60, reason: "The hub has not answered.")
        #expect(due(tries: ["vps": failed]).isEmpty)
        #expect(due(tries: ["vps": failed], at: now + 600) == ["vps"])
        let unset = try CentralVaultPlanTests.reading(central: nil)
        #expect(MacVaultPin.seedsDue(unset, records: [:], removed: [], removedKnown: true, tries: [:], now: now).isEmpty)
    }

    /// Bug: the rule catches each server, so a Linux server's key goes into the record, and the next key that its root
    /// read gives (a new install of its vault) stops; or a Linux server whose bound key is not its pin gets no read.
    @Test func aLinuxServerKeepsTheStepOfBefore() {
        let words: [(String?, Set<String>)] = [("linux", ["linux"]), (nil, []), ("linux", []), (nil, ["linux"])]
        for (kind, os) in words {
            let rule = MacVaultPin(kind: kind, os: os, record: nil)
            let said = "\(kind ?? "no kind"), \(os.sorted())"
            #expect(!rule.covered && !rule.keeps, "\(said)")
            #expect(rule.mayRead(bound: Self.agents) && rule.signs(found: Self.agents, bound: Self.agents) == Self.agents, "\(said)")
            #expect(rule.signs(found: Self.earlier, bound: Self.agents) == nil, "\(said): the read key is the bound key")
        }
    }
}
