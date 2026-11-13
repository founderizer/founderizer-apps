import Foundation
import Testing
@testable import FleetCore

/// What the app does about the central vault by itself (`VaultPlan`): the install while the hub reads no vault, the
/// recovery key, each server's pin, the 10 minutes and 6 tries of each step, and the one thing it never does by
/// itself — take the vault over from another Mac.
struct CentralVaultPlanTests {
    static let vaultKey = "age1wxf6a2an5vh325jh25qs9dpemgwrxp0lgsuxhkr9yqtpyzfq99assg55x8"
    static let serverKey = CentralVaultTests.recipient
    static let now = 1_761_300_000.0

    /// A reading with four machines: vps trusted, worker4 pinned to another key, mac-studio with no carrier, newbox not
    /// pinned yet.
    static func reading(central: String?, recovery: Bool = false, ok: Bool = true, source: String? = nil,
                        program: String? = nil) throws -> VaultReading {
        let status = central.map { key in
            #"{"ok": \#(ok), "recipient": "\#(key)", "fleet": "0f1e2d3c4b5a6978", "owner_keys": 1, "pins": {}, "#
                + #""recovery": \#(recovery ? "\"\(vaultKey)\"" : "null"), "items": 0, "#
                + #""source": \#(source.map { "\"\($0)\"" } ?? "null")}"#
        } ?? "null"
        let json = """
            {"db": "gen-1", "fleet": "0f1e2d3c4b5a6978", "central": \(status), "program": \(program.map { "\"\($0)\"" } ?? "null"),
             "read_at": null, "error": null, "held": {}, "machines": [
              {"machine": "vps", "carrier": "vps", "broker_recipient": "\(serverKey)", "pinned": "\(serverKey)", "matches": true, "missing": []},
              {"machine": "worker4", "carrier": "worker4", "broker_recipient": "\(serverKey)", "pinned": "\(vaultKey)", "matches": false,
               "missing": ["pin_mismatch"]},
              {"machine": "mac-studio", "carrier": null, "broker_recipient": null, "pinned": null, "matches": false,
               "missing": ["broker_without_deposits"]},
              {"machine": "newbox", "carrier": "newbox", "broker_recipient": "\(serverKey)", "pinned": null, "matches": false,
               "missing": ["not_pinned"]}]}
            """
        return try JSONDecoder().decode(VaultReading.self, from: Data(json.utf8))
    }

    /// The facts of the Mac that set the vault up: its owner key, and its pin of the vault's key.
    static func mine(keyHeld: Bool = true, pin: String? = vaultKey, hubOnRecord: Bool = true, otherOwner: Bool = false,
                     confirmedRecovery: String? = nil, confirmedPins: [String: String] = [:], install: VaultTries? = nil,
                     recovery: VaultTries? = nil, servers: [String: VaultTries] = [:], update: VaultTries? = nil,
                     now: Double = now) -> VaultFacts {
        VaultFacts(keyHeld: keyHeld, pin: pin, hubOnRecord: hubOnRecord, otherOwner: otherOwner, confirmedRecovery: confirmedRecovery,
                   confirmedPins: confirmedPins, install: install, recovery: recovery, servers: servers, update: update, now: now)
    }

    /// Six failures in a row, ten minutes apart, the last one `since` seconds before `now`.
    static func gaveUp(_ reason: String, since: Double = 60) -> VaultTries {
        (0..<6).reduce(nil as VaultTries?) { tries, n in
            VaultTries.failed(after: tries, at: now - since - Double(5 - n) * 600, reason: reason)
        }!
    }

    @Test func nothingRunsWithoutAVaultToReadOrAFleetToNameIt() throws {
        #expect(VaultPlan.of(nil, facts: Self.mine()) == .none)            // an older hub answered 404
        let nameless = try JSONDecoder().decode(VaultReading.self, from: Data(#"{"db": "gen-1", "central": null, "machines": [], "held": {}}"#.utf8))
        #expect(VaultPlan.of(nameless, facts: Self.mine()) == .none)
        #expect(VaultPlan.of(try Self.reading(central: Self.vaultKey, ok: false), facts: Self.mine()) == .none)
    }

    @Test func theInstallRunsWhileTheHubReadsNoVaultAndItsMachineIsOnRecord() throws {
        let unset = try Self.reading(central: nil)
        #expect(VaultPlan.of(unset, facts: Self.mine()) == VaultPlan(step: .install))
        // A Mac without a key or a pin installs as well: its install leaves a vault that another Mac's key holds as it
        // is, and says so (`otherOwner`).
        #expect(VaultPlan.of(unset, facts: Self.mine(keyHeld: false, pin: nil)) == VaultPlan(step: .install))
        #expect(VaultPlan.of(unset, facts: Self.mine(hubOnRecord: false)) == .none)
    }

    @Test func aFailedInstallIsTriedAgainAfterTenMinutesAtMostSixTimes() throws {
        let unset = try Self.reading(central: nil)
        var tries: VaultTries?
        for attempt in 1...6 {
            let at = Self.now + Double(attempt - 1) * 600
            #expect(VaultPlan.of(unset, facts: Self.mine(install: tries, now: at)).step == .install, "try \(attempt)")
            tries = VaultTries.failed(after: tries, at: at, reason: "try \(attempt) failed")
            if attempt < 6 {
                #expect(VaultPlan.of(unset, facts: Self.mine(install: tries, now: at + 599)) == .none, "the wait after try \(attempt)")
            }
        }
        // After six in a row there is no seventh: the row says why, and Retry is the owner's.
        #expect(tries?.failures == 6 && tries?.givenUp == true)
        #expect(VaultPlan.of(unset, facts: Self.mine(install: tries, now: Self.now + 86_400))
                == VaultPlan(step: .nothing, vault: .retry(.install, "try 6 failed")))
    }

    @Test func aSecondMacNeverTakesTheVaultByItself() throws {
        let set = try Self.reading(central: Self.vaultKey)
        let takeOver = VaultPlan(step: .takeOver, vault: .setUp(nil))
        // No owner key, or no pin of the vault's key: nothing runs, not even the recovery key or a server's pin, and
        // Set up is the owner's.
        #expect(VaultPlan.of(set, facts: Self.mine(keyHeld: false)) == takeOver)
        #expect(VaultPlan.of(set, facts: Self.mine(pin: nil)) == takeOver)
        #expect(VaultPlan.of(set, facts: Self.mine(keyHeld: false, pin: nil)) == takeOver)
        #expect(VaultPlan.of(try Self.reading(central: Self.vaultKey, recovery: true), facts: Self.mine(pin: nil)) == takeOver)
        // A pin of another key: the hub names a vault that this Mac did not pin.
        #expect(VaultPlan.of(set, facts: Self.mine(pin: Self.serverKey)) == VaultPlan(step: .takeOver, vault: .setUp(VaultPlan.otherKey)))
        // The hub reads no vault, and the app's own install found one that another Mac's key holds: no install again.
        #expect(VaultPlan.of(try Self.reading(central: nil), facts: Self.mine(otherOwner: true))
                == VaultPlan(step: .takeOver, vault: .setUp(VaultPlan.otherOwner)))
    }

    @Test func thisMacsVaultGetsItsRecoveryKeyAndThenItsServers() throws {
        let set = try Self.reading(central: Self.vaultKey)
        #expect(VaultPlan.of(set, facts: Self.mine()) == VaultPlan(step: .recover))
        // Once the vault has its recovery key (sent in this session, or in the hub's reading): each server whose key is
        // not pinned as it reports it, in the hub's order. One with no carrier or no key is not a server to trust.
        #expect(VaultPlan.of(set, facts: Self.mine(confirmedRecovery: Self.vaultKey)) == VaultPlan(step: .trust(["worker4", "newbox"])))
        let recovered = try Self.reading(central: Self.vaultKey, recovery: true)
        #expect(VaultPlan.of(recovered, facts: Self.mine()) == VaultPlan(step: .trust(["worker4", "newbox"])))
        // A pin this session confirmed counts before the hub's next reading shows it, for that very key only.
        #expect(VaultPlan.of(recovered, facts: Self.mine(confirmedPins: ["worker4": Self.serverKey])) == VaultPlan(step: .trust(["newbox"])))
        #expect(VaultPlan.of(recovered, facts: Self.mine(confirmedPins: ["worker4": Self.serverKey, "newbox": Self.serverKey])) == .none)
        #expect(VaultPlan.of(recovered, facts: Self.mine(confirmedPins: ["worker4": Self.vaultKey])) == VaultPlan(step: .trust(["worker4", "newbox"])))
    }

    @Test func eachServerWaitsAndGivesUpOnItsOwn() throws {
        let recovered = try Self.reading(central: Self.vaultKey, recovery: true)
        let worker4 = Self.gaveUp("This Mac does not know the host key of worker4 yet.")
        let newbox = VaultTries.failed(after: nil, at: Self.now - 60, reason: "sudo: a password is required")
        let row = VaultServerNeed(machine: "worker4", reason: "This Mac does not know the host key of worker4 yet.")
        // worker4 gave up and is a row; newbox failed a minute ago and waits, so nothing runs now.
        #expect(VaultPlan.of(recovered, facts: Self.mine(servers: ["worker4": worker4, "newbox": newbox]))
                == VaultPlan(step: .nothing, servers: [row]))
        // Ten minutes after its try, newbox goes again, and worker4 stays a row.
        #expect(VaultPlan.of(recovered, facts: Self.mine(servers: ["worker4": worker4, "newbox": newbox], now: Self.now + 540))
                == VaultPlan(step: .trust(["newbox"]), servers: [row]))
        // A server the hub reports trusted now is no row, whatever its tries said.
        #expect(VaultPlan.of(recovered, facts: Self.mine(servers: ["vps": Self.gaveUp("old")], now: Self.now)).servers.isEmpty)
    }

    @Test func aRecoveryThatGaveUpIsARowAndTheServersGoOn() throws {
        let set = try Self.reading(central: Self.vaultKey)
        #expect(VaultPlan.of(set, facts: Self.mine(recovery: Self.gaveUp("The vault refused this statement.")))
                == VaultPlan(step: .trust(["worker4", "newbox"]), vault: .retry(.recover, "The vault refused this statement.")))
        // One that failed a minute ago waits without a row, and the servers do not wait for it.
        let once = VaultTries.failed(after: nil, at: Self.now - 60, reason: "The hub did not answer.")
        #expect(VaultPlan.of(set, facts: Self.mine(recovery: once)) == VaultPlan(step: .trust(["worker4", "newbox"])))
    }

    /// UI-API 1.87: the vault runs another program than the hub's release, so this Mac runs the install's root step
    /// again by itself. Its tries wait ten minutes, six at most, and then it waits without a row: the next release's
    /// program starts them again (CentralVaultModel). A vault that is not this Mac's is never updated by itself.
    @Test func aVaultBehindTheHubsReleaseIsUpdatedByItselfWithNoRow() throws {
        let release = String(repeating: "a", count: 64), running = String(repeating: "b", count: 64)
        let behind = try Self.reading(central: Self.vaultKey, recovery: true, source: running, program: release)
        #expect(behind.programBehind)
        #expect(VaultPlan.of(behind, facts: Self.mine()) == VaultPlan(step: .update))
        let once = VaultTries.failed(after: nil, at: Self.now, reason: "The install on hub stopped: no clone.")
        #expect(VaultPlan.of(behind, facts: Self.mine(update: once, now: Self.now + 599)) == VaultPlan(step: .trust(["worker4", "newbox"])))
        #expect(VaultPlan.of(behind, facts: Self.mine(update: once, now: Self.now + 600)) == VaultPlan(step: .update))
        let used = Self.gaveUp("The install on hub stopped: no clone.")
        #expect(VaultPlan.of(behind, facts: Self.mine(update: used, now: Self.now + 86_400)) == VaultPlan(step: .trust(["worker4", "newbox"])))
        // The same program, or a side that says nothing, is no update.
        #expect(VaultPlan.of(try Self.reading(central: Self.vaultKey, recovery: true, source: release, program: release),
                             facts: Self.mine()) == VaultPlan(step: .trust(["worker4", "newbox"])))
        #expect(VaultPlan.of(try Self.reading(central: Self.vaultKey, recovery: true, program: release),
                             facts: Self.mine()) == VaultPlan(step: .trust(["worker4", "newbox"])))
        // The recovery key comes first; a vault that does not answer, or that is not this Mac's, gets nothing.
        #expect(VaultPlan.of(try Self.reading(central: Self.vaultKey, source: running, program: release), facts: Self.mine())
                == VaultPlan(step: .recover))
        #expect(VaultPlan.of(try Self.reading(central: Self.vaultKey, recovery: true, ok: false, source: running, program: release),
                             facts: Self.mine()) == .none)
        #expect(VaultPlan.of(behind, facts: Self.mine(keyHeld: false)) == VaultPlan(step: .takeOver, vault: .setUp(nil)))
        #expect(VaultPlan.of(behind, facts: Self.mine(pin: Self.serverKey)).step == .takeOver)
    }

    /// The hub keeps a fresh pin of each trusted server (`hub.py` `handover_key` needs one), so its pin is signed again
    /// once the hub's kept one is `pinRefresh` old or missing, from a hub that says when it was signed; an older hub's
    /// silence starts nothing, and after a success the next re-sign of that server waits a day.
    @Test func aTrustedServersPinIsSignedAgainWhenTheHubsKeptPinIsOld() throws {
        func reading(_ kept: String?) throws -> VaultReading {
            let field = kept.map { ", \"kept_pin_at\": " + $0 } ?? ""
            let json = """
                {"db": "gen-1", "fleet": "0f1e2d3c4b5a6978", "central": {"ok": true, "recipient": "\(Self.vaultKey)",
                 "fleet": "0f1e2d3c4b5a6978", "owner_keys": 1, "pins": {}, "recovery": "\(Self.vaultKey)", "items": 0,
                 "source": null}, "program": null, "read_at": null, "error": null, "held": {}, "machines": [
                  {"machine": "vps", "carrier": "vps", "broker_recipient": "\(Self.serverKey)", "pinned": "\(Self.serverKey)",
                   "matches": true, "missing": []\(field)}]}
                """
            return try JSONDecoder().decode(VaultReading.self, from: Data(json.utf8))
        }
        let day = 86400.0, fresh = Int(Self.now - 6 * day), old = Int(Self.now - 8 * day)
        #expect(VaultPlan.of(try reading(nil), facts: Self.mine()).step == .nothing)            // an older hub says nothing
        #expect(VaultPlan.of(try reading(String(fresh)), facts: Self.mine()).step == .nothing)
        #expect(VaultPlan.of(try reading(String(old)), facts: Self.mine()).step == .trust(["vps"]))
        #expect(VaultPlan.of(try reading("null"), facts: Self.mine()).step == .trust(["vps"]))  // the hub keeps none
        var signed = Self.mine()
        signed.signedAt = ["vps": Self.now - 60]                                                // on its way to the hub
        #expect(VaultPlan.of(try reading("null"), facts: signed).step == .nothing)
        signed.signedAt = ["vps": Self.now - VaultTries.wait - 1]                                // a day, not ten minutes
        #expect(VaultPlan.of(try reading("null"), facts: signed).step == .nothing)
        signed.signedAt = ["vps": Self.now - VaultPlan.resignWait - 1]
        #expect(VaultPlan.of(try reading("null"), facts: signed).step == .trust(["vps"]))
        #expect(try reading(String(old)).machines[0].kept_pin_at == old)
        #expect(try reading(nil).machines[0].keptPinKnown == false)
        #expect(try reading("null").machines[0].keptPinKnown && reading("null").machines[0].kept_pin_at == nil)
        #expect(VaultPlan.pinRefresh == 7 * day)
    }

    /// A re-sign never gives up: after its sixth failure in a row its server row shows (the row that exists for a server
    /// the automatic trust gave up on), and it is tried again each hour. A server's first trust keeps today's rule.
    @Test func aReSignThatGaveUpShowsItsRowAndGoesOnEachHour() throws {
        let reason = "Founderizer could not read its vault key on vps."
        let kept = try JSONDecoder().decode(VaultReading.self, from: Data("""
            {"db": "gen-1", "fleet": "0f1e2d3c4b5a6978", "central": {"ok": true, "recipient": "\(Self.vaultKey)",
             "fleet": "0f1e2d3c4b5a6978", "owner_keys": 1, "pins": {}, "recovery": "\(Self.vaultKey)", "items": 0,
             "source": null}, "program": null, "read_at": null, "error": null, "held": {}, "machines": [
              {"machine": "vps", "carrier": "vps", "broker_recipient": "\(Self.serverKey)", "pinned": "\(Self.serverKey)",
               "matches": true, "missing": [], "kept_pin_at": null}]}
            """.utf8))
        var facts = Self.mine()
        facts.servers = ["vps": Self.gaveUp(reason)]                                            // its sixth failure, a minute ago
        let now = VaultPlan.of(kept, facts: facts)
        #expect(now.step == .nothing && now.servers == [VaultServerNeed(machine: "vps", reason: reason)])
        facts.servers = ["vps": Self.gaveUp(reason, since: VaultPlan.retryEvery + 60)]          // an hour later
        let later = VaultPlan.of(kept, facts: facts)
        #expect(later.step == .trust(["vps"]) && later.servers.map(\.machine) == ["vps"])
        // The first trust of a server that is not pinned yet keeps its rule of today: six tries, then the owner's Retry.
        var first = Self.mine()
        first.servers = ["newbox": Self.gaveUp(reason, since: VaultPlan.retryEvery + 60)]
        let plan = VaultPlan.of(try Self.reading(central: Self.vaultKey, recovery: true), facts: first)
        #expect(plan.step == .trust(["worker4"]))
        #expect(plan.servers.map(\.machine) == ["newbox"])
    }

    @Test func triesCountInARow() {
        let first = VaultTries.failed(after: nil, at: 100, reason: "a")
        #expect(first.failures == 1 && !first.givenUp && !first.isDue(at: 699) && first.isDue(at: 700))
        let sixth = (2...6).reduce(first) { tries, n in VaultTries.failed(after: tries, at: 100 + Double(n) * 600, reason: "\(n)") }
        #expect(sixth.failures == 6 && sixth.givenUp && !sixth.isDue(at: 1e12) && sixth.reason == "6")
        #expect(VaultTries.most == 6 && VaultTries.wait == 600)
    }
}
