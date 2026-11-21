import AppKit
import Foundation
import Testing
@testable import FleetVaultCore

/// **A sign-in names its cause** (`~/dev/founderizer-plans/vault-signin-causes-spec.md`, 20 November 2026): each try of
/// the Browser Agent on the fleet's Mac Studio ended in one sentence, "Chrome did not confirm the sign-in", while Chrome's
/// menu item "Allow JavaScript from Apple Events" had no tick, and nothing said so.
struct VaultSigninCausesTests {
    /// Of an AppleScript error only its number is read: its message can hold the script, and so the password. A bug
    /// that passes the message on, or reads a cause from it, fails here.
    @Test func anAppleScriptErrorIsItsNumberOnly() {
        let secret = "hunter2-not-a-real-password"
        func error(_ number: Int?) -> NSDictionary {
            var fields: [String: Any] = [NSAppleScript.errorMessage: "execute javascript \"set('\(secret)')\" failed",
                                         NSAppleScript.errorBriefMessage: secret]
            if let number { fields[NSAppleScript.errorNumber] = number }
            return fields as NSDictionary
        }
        #expect(VaultBrowser.failure(error(12)) as? VaultFailure == .chromeJavaScriptOff)
        #expect(VaultBrowser.failure(error(-1743)) as? VaultFailure == .chromeRefused)
        #expect(VaultBrowser.failure(error(-1744)) as? VaultFailure == .chromeNotAsked)
        #expect(VaultBrowser.failure(error(-600)) as? VaultFailure == .chromeNotRunning)
        #expect(VaultBrowser.failure(error(-1712)) as? VaultChromeError == VaultChromeError(number: -1712))
        #expect(VaultBrowser.failure(error(nil)) as? VaultFailure == .chromeError)
        for number in [12, -1743, -1744, -600, -1712, nil] {
            let said = String(describing: VaultBrowser.failure(error(number)))
            #expect(!said.contains(secret), "\(said)")
        }
    }

    /// Each answer of a page names its own cause; an answer that is no page's is Chrome's. A bug that folds two causes
    /// into one sentence again fails here (the looks' causes: `theFlowTypesThePasswordOnce`), and so does one that keeps
    /// Chrome's own words for a timeout during a step, after which Chrome can still type.
    @Test func eachAnswerOfThePageNamesItsCause() {
        let fills: [(String, VaultFailure)] = [("no-tab", .signinNoTab), ("wrong-origin", .signinNoTab),
                                               ("no-form", .signinNoForm), ("wrong-action", .signinWrongAction),
                                               ("bad-field", .signinBadField), ("moved", .signinMoved),
                                               ("not-sent", .signinUnknown), ("", .signinUnknown),
                                               ("something new", .signinUnknown)]
        for (answer, failure) in fills { #expect(VaultBrowser.fillFailure(answer) == failure, "\(answer)") }
        // After the login went, a code page that the vault cannot fill wants a person; nothing asks for the page again.
        #expect(VaultBrowser.codeFailure("no-form") == .signinCode)
        for answer in ["no-tab", "wrong-origin", "bad-field", ""] { #expect(VaultBrowser.codeFailure(answer) == .signinUnknown, "\(answer)") }
        // An end after the fill keeps only the site's refusal and a code; a Chrome error in a look, Chrome's own words and
        // a stop are unknown: words that send the agent back to the sign-in page would invite a second typing.
        #expect(VaultBrowser.afterFillFailure(VaultFailure.signinCode) == .signinCode)
        #expect(VaultBrowser.afterFillFailure(VaultFailure.signinRefused) == .signinRefused)
        for error: Error in [VaultChromeError(number: -1712), VaultFailure.chromeError, VaultFailure.signinNoTab,
                             VaultFailure.signinNoForm, CancellationError()] {
            #expect(VaultBrowser.afterFillFailure(error) == .signinUnknown, "\(error)")
        }
        // Before the password went, a timeout during a step is unknown: Chrome can still run the script after it, and
        // type. Chrome's causes that ran nothing stay, and so does a timeout outside a step.
        let timeout = VaultChromeError(number: -1712)
        #expect(VaultBrowser.endFailure(timeout, typed: false, stepping: true) as? VaultFailure == .signinUnknown)
        #expect(VaultBrowser.endFailure(timeout, typed: false, stepping: false) as? VaultChromeError == timeout)
        #expect(VaultBrowser.endFailure(timeout, typed: true, stepping: false) as? VaultFailure == .signinUnknown)
        for cause in [VaultFailure.chromeJavaScriptOff, .chromeRefused, .chromeNotRunning] {
            #expect(VaultBrowser.endFailure(cause, typed: false, stepping: true) as? VaultFailure == cause, "\(cause)")
        }
        // Each cause has words of its own.
        let words = Set(fills.map(\.1.rawValue) + [VaultFailure.signinRefused, .signinCode, .signinChallenge].map(\.rawValue))
        #expect(words.count == 9)
    }

    /// The Mac's reading looks at every Chrome window, not only the front one: a profile with no tick in any window is
    /// `javascript_off` (on the Mac Studio the front window's profile had the tick and the agent's had none), and `ok`
    /// needs each window that can run the script to pass. A check of the front window alone fails the first line.
    @Test func theChromeReadingAsksEachWindowAndAnyProfileWithNoTickIsOff() {
        #expect(VaultBrowser.probeSource.contains("repeat with w in windows"))
        #expect(VaultBrowser.probeSource.contains("execute active tab of w"))
        #expect(!VaultBrowser.probeSource.contains("front window"))
        #expect(VaultBrowser.probeSource.contains("if n is -1712 then return -1712"))     // no 10 seconds for each dead tab
        #expect(VaultBrowser.probeCause(0) == ("ok", nil))
        #expect(VaultBrowser.probeCause(12) == ("javascript_off", nil))
        #expect(VaultBrowser.probeCause(-1728) == ("no_window", nil) && VaultBrowser.probeCause(-1719) == ("no_window", nil))
        let other = VaultBrowser.probeCause(-1712)
        #expect(other.cause == "error" && other.number == -1712)
    }

    /// The tab's id and the page's words come back together, also for an id of 2^30 or more: the looks after the fill go
    /// only to the tab that took it. A bug that reads the id as text, or the answer of another shape as a tab, fails here.
    @Test func theTabAnswerIsItsIdAndItsWords() {
        func list(_ items: NSAppleEventDescriptor...) -> NSAppleEventDescriptor {
            let answer = NSAppleEventDescriptor.list()
            for (at, item) in items.enumerated() { answer.insert(item, at: at + 1) }
            return answer
        }
        let big = Int32(1 << 30) + 7
        let filled = VaultBrowser.tabAnswer(list(NSAppleEventDescriptor(int32: big), NSAppleEventDescriptor(string: "filled")))
        #expect(filled.id == Int(big) && filled.answer == "filled")
        let none = VaultBrowser.tabAnswer(list(NSAppleEventDescriptor(int32: 0), NSAppleEventDescriptor(string: "no-tab")))
        #expect(none.id == 0 && none.answer == "no-tab")
        let other = VaultBrowser.tabAnswer(NSAppleEventDescriptor(string: "filled"))
        #expect(other.id == 0 && other.answer == "")
    }
}
