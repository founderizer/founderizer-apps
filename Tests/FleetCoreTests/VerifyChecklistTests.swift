import Foundation
import Testing
@testable import FleetCore

/// The checklist of one machine (PRODUCT.md 4.1). The rule that costs a reader most is the one tested first: **a
/// check that does not apply to a machine is absent from the array, and a missing id is never a pass.**
struct VerifyChecklistTests {
    private func checklist(_ body: String) throws -> VerifyChecklist {
        try VerifyChecklist.decode(Data(body.utf8))
    }

    @Test func aMissingCheckIsNotAPassAndNotAFailure() throws {
        // The owner's own Mac: six answers, all ok. `hub_answers`, `owner_claimed` and the three service checks are
        // not this machine's business, so they are not in the array and not on the screen.
        let mac = try checklist("""
        [{"check": "tailnet", "state": "ok", "says": "100.96.10.20", "fix": null},
         {"check": "firewall", "state": "ok", "says": "the firewall is on", "fix": null},
         {"check": "clock", "state": "ok", "says": "0.2 seconds from the hub", "fix": null},
         {"check": "disk", "state": "ok", "says": "180 GiB free", "fix": null},
         {"check": "selftest", "state": "ok", "says": "116 of 121, the recorded baseline", "fix": null},
         {"check": "version", "state": "ok", "says": "8e022d9 on config", "fix": null}]
        """)
        #expect(mac.checks.count == 6)
        #expect(mac.isReady)
        #expect(mac.line == "READY")
        #expect(mac.checks.map(\.check).contains("services") == false)
        #expect(mac.summary == "Ready. Every check of this server passed.")
    }

    @Test func aMachineThatSaidNothingIsNotReady() throws {
        let nothing = try checklist("[]")
        #expect(nothing.isReady == false)
        #expect(nothing.line == "Not checked")
        #expect(nothing.summary == "This server has not been checked yet.")
    }

    @Test func aWarningIsNotAFailure() throws {
        let warned = try checklist("""
        [{"check": "version", "state": "warn", "says": "3b853ed on claude/x, not on config", "fix": "Update this machine."},
         {"check": "disk", "state": "ok", "says": "40 GiB free", "fix": null}]
        """)
        #expect(warned.isReady)
        #expect(warned.line == "READY")
        #expect(warned.warning.count == 1)
        #expect(warned.summary == "Ready, with 1 warning.")
    }

    @Test func aFailedCheckCarriesItsOwnFix() throws {
        let broken = try checklist("""
        [{"check": "runtime_signed_in", "state": "fail", "says": "claude is not signed in",
          "fix": "Machines, this machine, Sign in."},
         {"check": "services", "state": "fail", "says": "fleet-writer is not running",
          "fix": "systemctl --user start fleet-writer"}]
        """)
        #expect(broken.isReady == false)
        // The order is the order of 4.1, whatever order the machine answered in.
        #expect(broken.checks.map(\.check) == ["services", "runtime_signed_in"])
        #expect(broken.line == "NOT READY: services, runtime_signed_in")
        #expect(broken.summary == "2 checks failed: Services, Signed in.")
        #expect(broken.failing.first?.fix == "systemctl --user start fleet-writer")
    }

    @Test func oneFailedCheckPointsAtItsFix() throws {
        let one = try checklist("""
        [{"check": "disk", "state": "fail", "says": "0.4 GiB free where the checkout is",
          "fix": "Make room on this machine."}]
        """)
        #expect(one.summary == "Disk space failed. Its fix is below.")
    }

    @Test func aMachineThatIsOnlyNotSignedInIsNotABrokenInstall() throws {
        let fresh = try checklist("""
        [{"check": "services", "state": "ok", "says": "fleet-writer is active", "fix": null},
         {"check": "runtime_signed_in", "state": "fail", "says": "claude is installed and not signed in",
          "fix": "Machines, this machine, Sign in."}]
        """)
        #expect(fresh.isReady == false)
        #expect(fresh.onlyNeedsSignIn)
        #expect(fresh.summary.hasPrefix("This server is in your fleet."))
        // One more failed check, and it is an install with something wrong in it again.
        let broken = try checklist("""
        [{"check": "services", "state": "fail", "says": "fleet-writer is not running", "fix": "Start it."},
         {"check": "runtime_signed_in", "state": "fail", "says": "claude is not signed in", "fix": "Sign in."}]
        """)
        #expect(broken.onlyNeedsSignIn == false)
        #expect(try checklist("[]").onlyNeedsSignIn == false)
    }

    @Test func anAnswerOutsideTheFrozenShapeIsNoAnswer() throws {
        let refused = [
            "[{\"check\": \"disk\", \"state\": \"broken\", \"says\": \"x\", \"fix\": null}]",      // not one of the three states
            "[{\"check\": \"disk\", \"state\": \"ok\", \"says\": \"\", \"fix\": null}]",            // no line
            "[{\"check\": \"disk\", \"state\": \"ok\", \"says\": \"x\", \"fix\": \"y\"}]",          // a pass with a fix
            "[{\"check\": \"Disk\", \"state\": \"ok\", \"says\": \"x\", \"fix\": null}]",           // not an id
            "[{\"check\": \"disk\", \"state\": \"ok\", \"says\": \"x\", \"fix\": null},"
                + "{\"check\": \"disk\", \"state\": \"fail\", \"says\": \"y\", \"fix\": \"z\"}]",   // the same id twice
            "{\"check\": \"disk\"}",                                                                // not the array
        ]
        for body in refused {
            #expect(throws: (any Error).self) { try checklist(body) }
        }
    }

    @Test func aLaterVersionMayAddAnIdAndTheScreenStillReadsIt() throws {
        let later = try checklist("""
        [{"check": "version", "state": "ok", "says": "8e022d9", "fix": null},
         {"check": "backups", "state": "warn", "says": "no backup in 3 days", "fix": "Look at the backup job."}]
        """)
        // The ids this version knows come first, in their own order; one it does not know keeps its place after them.
        #expect(later.checks.map(\.check) == ["version", "backups"])
        #expect(later.checks.last?.title == "Backups")
        #expect(later.isReady)
    }

    @Test func theChecklistIsReadOutOfAnInstallsOwnOutput() {
        let output = """
        Fleet: verify: is this machine of the fleet healthy?
        ok    disk: 120 GiB free
        [{"check": "disk", "state": "ok", "says": "120 GiB free", "fix": null}]
        READY
        """
        let found = VerifyChecklist.read(output: output, readAt: 1_791_000_000)
        #expect(found?.checks.count == 1)
        #expect(found?.readAt == 1_791_000_000)
        #expect(found?.isReady == true)
        #expect(VerifyChecklist.read(output: "Fleet install stopped: no systemd\n") == nil)
    }

    @Test func everyIdOfThisVersionHasItsOwnTitle() {
        #expect(VerifyChecklist.ids.count == 13)
        for id in VerifyChecklist.ids {
            let title = VerifyChecklist.title(id)
            #expect(!title.isEmpty)
            #expect(title != id)
        }
    }
}
