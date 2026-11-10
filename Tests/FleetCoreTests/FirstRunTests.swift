import Foundation
import Testing
@testable import FleetCore

/// The first thing a customer sees (PRODUCT.md 2): the line of a new hub's installer, which carries its claim, the
/// one question that is asked only when it is needed, and what this Mac says when it cannot reach a hub. The owner's
/// words for all three, because this is the screen that decides whether they get a fleet at all.
struct FirstRunTests {
    // MARK: the line of a new hub's installer

    @Test func theLineTheAgentPrintsCarriesTheHubsOwnAddress() {
        let line = "FLEET_CLAIM=7KMQ-2PRJ-4TVW sh -c \"$(curl -fsS http://100.64.0.9:8765/claim)\""
        #expect(ClaimCode.hubAddress(in: line) == "http://100.64.0.9:8765")
        #expect(ClaimCode.found(in: line)?.code == "7KMQ2PRJ4TVW")
        // The agent's whole report around it is fine: the line is found in it.
        let report = """
        I installed the hub. Run this on your own Mac:

          FLEET_CLAIM=7KMQ-2PRJ-4TVW sh -c "$(curl -fsS http://100.64.0.9:8765/claim)"

        Then paste the address in the app.
        """
        #expect(ClaimCode.hubAddress(in: report) == "http://100.64.0.9:8765")
    }

    @Test func anAddressTheOwnerTypesIsTakenInEveryShapeTheyWouldType() {
        #expect(ClaimCode.hubAddress(in: "http://100.84.1.2:8765") == "http://100.84.1.2:8765")
        #expect(ClaimCode.hubAddress(in: " 100.84.1.2 ") == "http://100.84.1.2:8765")
        #expect(ClaimCode.hubAddress(in: "100.84.1.2:9000") == "http://100.84.1.2:9000")
        #expect(ClaimCode.hubAddress(in: "my hub") == nil)
        #expect(ClaimCode.hubAddress(in: "") == nil)
    }

    // MARK: the question that is asked only when it is needed

    @Test func theTailscaleKeyIsAskedForOnlyWhenTheMachineNeedsOne() {
        #expect(InstallPlan.needsNetworkKey("The private network: This machine is not on your private network. "
                                            + "Give the Tailscale key of your fleet."))
        #expect(InstallPlan.needsNetworkKey("Fleet install stopped: No Tailscale auth key came in."))
        #expect(InstallPlan.needsNetworkKey("Tailscale did not join with that auth key."))
        // Everything else is a real failure and keeps its own words.
        #expect(InstallPlan.needsNetworkKey("Join the fleet: the hub refused this code") == false)
        #expect(InstallPlan.needsNetworkKey("Read the machine: This install needs Ubuntu 22.04") == false)
    }

    @Test func anInstallWithNoKeyAsksForNoneUntilTheMachineSaysItNeedsOne() {
        let plan = InstallPlan.join(target: InstallTarget(host: "198.51.100.7"), line: "line", code: "CODE12345678",
                                    authKey: nil)
        let network = plan.steps.first { $0.id == "network" }
        // With no key the step starts Tailscale's own sign-in, for the owner to approve, and asks for no key.
        if case .signIn(let start, let check, _, _)? = network?.action {
            #expect(start.contains("tailscale up --accept-dns=false --timeout=15m"))
            #expect((start + check).contains("auth-key") == false)
        } else {
            Issue.record("the network step asked for a key that nobody gave")
        }
        // The one-time join code is still taken out of every line; there is simply no key to take out.
        #expect(plan.redactions == ["CODE12345678"])
    }

    // MARK: what this Mac says when it cannot reach a hub

    private let hub = URL(string: "http://100.84.1.2:8765")!

    @Test func aHubThatCannotBeReachedIsSaidInWordsAPersonReads() {
        let ats = HubReach.words(URLError(.appTransportSecurityRequiresSecureConnection), hub: hub)
        #expect(ats.says == "This Mac refused to open a plain connection to your hub at 100.84.1.2:8765.")
        #expect(ats.next?.contains("setting of this app") == true)
        // The words of URLError itself never reach the owner.
        for error: any Error in [URLError(.cannotConnectToHost), URLError(.timedOut), URLError(.cannotFindHost),
                                 URLError(.notConnectedToInternet), URLError(.secureConnectionFailed),
                                 URLError(.badServerResponse)] {
            let words = HubReach.words(error, hub: hub)
            #expect(words.says.contains("App Transport Security") == false)
            #expect(words.says.contains("NSURLError") == false)
            #expect(words.says.contains("error") == false)
            #expect(words.next != nil, "\(error) left the owner with nothing to do")
        }
    }

    @Test func aHubThatAnswersSomebodyElseSaysSo() {
        let refused = HubReach.words(HubError.refusal(403, "owner only"), hub: hub)
        #expect(refused.says.contains("does not serve its pages to this Mac"))
        #expect(refused.next?.contains("Claim it from this Mac") == true)
        // Never the hub's own words in brackets (fix round 3, item 50).
        #expect(refused.line.contains("owner only") == false)
        let elsewhere = HubReach.words(HubError.refusal(404, "no"), hub: hub)
        #expect(elsewhere.says.contains("it is not a Founderizer hub"))
        let typed = HubReach.words(HubError.invalidAddress, hub: nil)
        #expect(typed.says == "That is not a hub address.")
        #expect(typed.next?.contains("http://100.84.1.2:8765") == true)
        // No status code in a line of his (review B8, fix round 2): it said "Your hub refused this read (503)."
        let starting = HubReach.words(HubError.refusal(503, "The hub is starting."), hub: hub)
        #expect(starting.says == "Your hub refused this read." && starting.next == "The hub is starting.")
    }

    /// The owner, 27 October 2026: "show the connection notice only after several failed reads in a row, and never
    /// for one short break".
    @Test func oneShortBreakSaysNothing() {
        #expect(!HubReach.tells(failedReads: 0, answeredBefore: true))
        #expect(!HubReach.tells(failedReads: 1, answeredBefore: true))
        #expect(!HubReach.tells(failedReads: 2, answeredBefore: true))
        #expect(HubReach.tells(failedReads: 3, answeredBefore: true))
        #expect(HubReach.tells(failedReads: 9, answeredBefore: true))
        // A hub that never answered, the first run's and a new address's, is said at once.
        #expect(HubReach.tells(failedReads: 1, answeredBefore: false))
        #expect(!HubReach.tells(failedReads: 0, answeredBefore: false))
    }

    /// **The first run tries again only what failed at once** (review A4, fix round 2): four claims that each timed
    /// out after 30 s kept "Checking your fleet" up for 2 min 16 s. A refused or lost connection, or a hub that is
    /// starting, is worth another try in two seconds; a time-out already waited, and an answer says the same again.
    @Test func onlyAReachThatFailedAtOnceIsTriedAgain() {
        for fast in [URLError.Code.cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet] {
            #expect(HubReach.worthAgain(URLError(fast)), "\(fast)")
        }
        #expect(HubReach.worthAgain(HubError.refusal(503, "The hub is starting.")))
        #expect(HubReach.worthAgain(HubError.unavailable))
        #expect(!HubReach.worthAgain(URLError(.timedOut)))
        #expect(!HubReach.worthAgain(URLError(.cancelled)))
        #expect(!HubReach.worthAgain(HubError.refusal(404, "no")))
        #expect(!HubReach.worthAgain(HubError.invalidAddress))
        #expect(!HubReach.worthAgain(CancellationError()))
        #expect(HubReach.triesAgain == 3)
        #expect(HubReach.pause == .seconds(2))
    }
}
