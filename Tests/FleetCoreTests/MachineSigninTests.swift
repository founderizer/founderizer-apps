import Foundation
import Testing
@testable import FleetCore

/// The app's half of the per-machine sign-in (`machine_signin`). The link comes from the machine, so the app checks it
/// as the hub does: only the provider's own host, only HTTPS, no user part and no port. A machine must not be able to
/// put a page of its own in front of the owner, and the owner's click must go to the provider and nowhere else.
struct MachineSigninTests {
    private func login(_ fields: String) throws -> MachineLogin {
        try JSONDecoder().decode(MachineLogin.self, from: Data(fields.utf8))
    }

    private func waiting(url: String, runtime: String = "claude", wants: Bool = true, shows: String? = nil) throws -> MachineLogin {
        let shown = shows.map { "\"\($0)\"" } ?? "null"
        return try login("""
        {"id": 3, "runtime": "\(runtime)", "state": "needs_owner", "detail": null, "started_at": 1, "updated_at": 2,
         "url": "\(url)", "shows_code": \(shown), "wants_code": \(wants)}
        """)
    }

    @Test func onlyTheProvidersOwnPageIsOffered() throws {
        #expect(try waiting(url: "https://claude.ai/oauth/authorize?code=1").signInURL?.host == "claude.ai")
        #expect(try waiting(url: "https://console.anthropic.com/login").signInURL != nil)
        #expect(try waiting(url: "https://auth.openai.com/activate", runtime: "codex", wants: false).signInURL != nil)
        for elsewhere in ["https://claude.ai.example.com/login", "https://evil.example/claude.ai",
                          "http://claude.ai/login", "https://claude.ai:8443/login",
                          "https://user@claude.ai/login", "https://auth.openai.com/activate"] {
            #expect(try waiting(url: elsewhere).signInURL == nil, "\(elsewhere) was offered to the owner")
        }
    }

    @Test func eachProviderKeepsToItsOwnHost() throws {
        #expect(try waiting(url: "https://claude.ai/login", runtime: "codex", wants: false).signInURL == nil)
        #expect(try waiting(url: "https://auth.openai.com/activate", runtime: "claude").signInURL == nil)
    }

    @Test func noLinkIsOfferedUntilTheSignInWaitsForTheOwner() throws {
        let starting = try login("""
        {"id": 1, "runtime": "claude", "state": "starting", "detail": null, "started_at": 1, "updated_at": 1,
         "url": "https://claude.ai/login", "shows_code": null, "wants_code": false}
        """)
        #expect(starting.signInURL == nil)
        #expect(starting.isOpen)
        #expect(!starting.waitsForOwner)
    }

    /// **A code that the hub lost on the way is asked for again** (owner API 1.92): a hub that restarted before the
    /// machine took the code puts the sign-in back to waiting for one. The setup page waits only while the sign-in has
    /// not moved since the code went, so it shows "Paste the code it gave you" again instead of "Signing in" for good.
    @Test func aCodeTheHubLostIsAskedForAgain() throws {
        func at(_ state: String, updated: Double) throws -> MachineLogin {
            try login("""
            {"id": 3, "runtime": "claude", "state": "\(state)", "detail": null, "started_at": 1, "updated_at": \(updated),
             "url": "https://claude.ai/login", "shows_code": null, "wants_code": true}
            """)
        }
        #expect(try at("needs_owner", updated: 2).codeOnItsWay(sentFrom: 2))       // the reading it went from: it waits
        #expect(try !at("signing_in", updated: 3).codeOnItsWay(sentFrom: 2))       // the hub took it: its state says so
        #expect(try !at("needs_owner", updated: 4).codeOnItsWay(sentFrom: 2))      // waiting for a code again: ask again
        #expect(try !at("needs_owner", updated: 2).codeOnItsWay(sentFrom: nil))    // nothing went
    }

    @Test func onlyACodeShapedCodeIsSent() {
        #expect(MachineLogin.code(" AbCd-1234 ") == "AbCd-1234")
        // Claude's own is `code#state`: two random parts and a hash, about ninety characters.
        let real = "aB3dE6gH9jK2mN5pQ8sT1vW4yZ7cF0hL#mK3bQ9wR2tV5yH8jL4nC6dF0gS1aZ7eX"
        #expect(MachineLogin.code(real) == real)
        for bad in ["ab", String(repeating: "a", count: 220), "code with spaces", "code;id", "a\nEnter", "", "-lead",
                    "$(id)", "../etc"] {
            #expect(MachineLogin.code(bad) == nil, "\(bad) would have been typed into a terminal")
        }
    }

    @Test func grokHasNoSignIn() {
        #expect(MachineLogin.runtimes == ["claude", "codex"])
        #expect(!MachineLogin.canSignIn("grok"))
        #expect(!MachineLogin.canSignIn("gemini"))
        #expect(MachineLogin.canSignIn("claude"))
        #expect(MachineLogin.canSignIn("codex"))
    }

    @Test func theCommandRefusesGrokAndAnyOtherRuntime() {
        #expect(throws: HubError.self) {
            _ = try OwnerCommand.machineSignin(agent: "solo", runtime: "grok", replace: false).bodyFields(text: "")
        }
        #expect(throws: HubError.self) {
            _ = try OwnerCommand.machineSigninCode(agent: "solo", code: "nope;id").bodyFields(text: "")
        }
        let body = try? OwnerCommand.machineSignin(agent: "solo", runtime: "claude", replace: false).bodyFields(text: "")
        #expect(body?["runtime"] as? String == "claude")
        #expect(body?["replace"] as? Bool == false)
        let sent = try? OwnerCommand.machineSigninCode(agent: "solo", code: " AbCd-1234 ").bodyFields(text: "")
        #expect(sent?["code"] as? String == "AbCd-1234")
        #expect(sent?.count == 1, "the code's command sends nothing else")
    }

    @Test func noLabelCarriesTheCode() {
        let label = OwnerCommand.machineSigninCode(agent: "solo", code: "AbCd-1234").label
        #expect(!label.contains("AbCd-1234"))
        #expect(label == "Send the sign-in code to Solo")
    }

    @Test func theCodeTheRuntimePrintedIsShownAsItIs() throws {
        let codex = try waiting(url: "https://auth.openai.com/activate", runtime: "codex", wants: false, shows: "WXYZ-1234")
        #expect(codex.deviceCode == "WXYZ-1234")
        #expect(!codex.waitsForCode, "Codex's code goes into the provider's page, not back into the app")
        #expect(codex.summary == "Open the link and enter WXYZ-1234 there.")
        let claude = try waiting(url: "https://claude.ai/login")
        #expect(claude.deviceCode == nil)
        #expect(claude.waitsForCode)
    }

    @Test func aMachineThatSaysNothingLeavesTheRowAlone() throws {
        let reading = try JSONDecoder().decode(MachineStatus.self, from: Data("""
        {"agent": "solo", "machine": "box", "role": "worker", "address": "100.64.0.9", "access": null,
         "revision": null, "update": {"state": null, "detail": null, "requested_at": null, "finished_at": null},
         "check": null, "security": {}, "runtime": {"name": "claude", "version": "2.1.287", "signed_in": false},
         "os": {"name": null, "kernel": null}, "reported_at": 1, "stale": false, "features": [],
         "models": null, "screen_models": null, "settings": null, "settings_pending": null, "verify": null,
         "runtimes": null, "login": null}
        """.utf8))
        #expect(reading.login == nil)
        #expect(reading.signInRuntime == "claude")
        #expect(reading.needsSignIn, "a machine that reports itself signed out is where the owner has work")
    }
}

// MARK: using a different account of the same provider

// No provider starts a second sign-in while one is live, so the owner who wants another account of the same provider
// needs the runtime signed out first. `replace` asks the hub for both halves as one job (the owner, 20 October 2026,
// with a manager at 92% of its weekly allowance and an idle account beside it).
@Test func anotherAccountAsksForBothHalvesAsOneCommand() throws {
    let body = try OwnerCommand.machineSignin(agent: "manager", runtime: "claude", replace: true).bodyFields(text: "")
    #expect(body["runtime"] as? String == "claude")
    // In the body, so a repeat of one request_id is the same request and a change of mind is a new one.
    #expect(body["replace"] as? Bool == true)
    #expect(body.count == 2, "the sign-in command sends nothing else")
}

@Test func theLabelSaysWhichOfTheTwoItIs() {
    #expect(OwnerCommand.machineSignin(agent: "manager", runtime: "claude", replace: true).label
            == "Use another Claude Code account for Manager")
    #expect(OwnerCommand.machineSignin(agent: "solo", runtime: "codex", replace: false).label
            == "Sign Solo in to Codex")
}

@Test func aSignOutIsAnOpenSignInAndSaysWhatIsHappening() throws {
    let out = try JSONDecoder().decode(MachineLogin.self, from: Data("""
        {"id": 3, "runtime": "claude", "state": "signing_out", "detail": null, "started_at": 1, "updated_at": 2,
         "url": null, "shows_code": null, "wants_code": false}
        """.utf8))
    #expect(out.isOpen, "the agent is already stopped, so nothing may offer to start a second sign-in")
    #expect(out.isSigningOut)
    #expect(out.summary == "Signing out of the account it used…")
    #expect(out.signInURL == nil, "there is no link yet, and none of the old account's is ever shown")
}

// Claude Code's own `/login` printed its link on `claude.com` on 20 October 2026. The app checks the host itself,
// as the hub does, so a host it does not know means the owner is offered no link and the sign-in dies silently.
@Test func theLinkMayBeOnAnyOfThatProvidersOwnHosts() throws {
    for host in ["claude.ai", "claude.com", "console.anthropic.com"] {
        let live = try JSONDecoder().decode(MachineLogin.self, from: Data("""
            {"id": 1, "runtime": "claude", "state": "needs_owner", "detail": null, "started_at": 1,
             "updated_at": 2, "url": "https://\(host)/cai/oauth/authorize?code=1", "shows_code": null,
             "wants_code": true}
            """.utf8))
        #expect(live.signInURL?.host == host, "\(host)")
    }
    // Still only that provider's own addresses: a machine must not put a page of its own in front of him.
    for host in ["claude.ai.example.com", "auth.openai.com", "evil.test"] {
        let other = try JSONDecoder().decode(MachineLogin.self, from: Data("""
            {"id": 1, "runtime": "claude", "state": "needs_owner", "detail": null, "started_at": 1,
             "updated_at": 2, "url": "https://\(host)/oauth", "shows_code": null, "wants_code": true}
            """.utf8))
        #expect(other.signInURL == nil, "\(host)")
    }
}
