import Foundation
import Testing
@testable import FleetCore

// **The pages of an agent's setup, on his own fleet of 25 October 2026.** Leo and Mia: Codex installed on their
// servers, the install stopped at the sign-in because the code expired after 15 minutes, nothing signed in. Ivy:
// Claude Code installed and signed in on mac-studio, never checked, not active.

private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

private func machine(runtime: String = "codex", signedIn: Bool? = false, pending: Bool = false,
                     login: [String: Any]? = nil, stale: Bool = false) throws -> MachineStatus {
    var fields: [String: Any] = ["agent": "leo", "machine": "vps", "role": "worker", "update": [:], "security": [:],
                                 "os": [:], "runtime": ["name": runtime, "signed_in": signedIn.map { $0 as Any } ?? NSNull()],
                                 "reported_at": 10_000, "settings_pending": pending, "stale": stale]
    if let login { fields["login"] = login }
    return try JSONDecoder().decode(MachineStatus.self, from: json(fields))
}

private func login(_ state: String, runtime: String = "codex", detail: String? = nil) -> [String: Any] {
    ["id": 4, "runtime": runtime, "state": state, "detail": detail.map { $0 as Any } ?? NSNull(), "started_at": 1, "updated_at": 2,
     "url": NSNull(), "shows_code": NSNull(), "wants_code": runtime == "claude"]
}

private func job(_ state: String, kind: String = "install", runtime: String = "codex", step: String? = "sign_in",
                 detail: String? = nil, agent: String = "leo", timedOut: Bool? = nil) throws -> ServerJob {
    var fields: [String: Any] = ["id": 4, "kind": kind, "agent": agent, "runtime": runtime, "state": state,
                                 "step": step.map { $0 as Any } ?? NSNull(), "detail": detail.map { $0 as Any } ?? NSNull(), "prompt": NSNull(),
                                 "created": 1, "updated": 2]
    if let timedOut { fields["timed_out"] = timedOut }
    return try JSONDecoder().decode(ServerJob.self, from: json(fields))
}

private let expired = "Codex did not sign in within 15 minutes. Try again in Fleet."

struct AgentSetupFlowTests {
    @Test func leoOpensOnItsProviderWithTheReasonItStoppedAndNoCodeIsStarted() throws {
        let failed = try job("failed", detail: expired)
        let leo = try machine()
        #expect(AgentSetupFlow.page(runtime: "codex", job: failed, machine: leo, switchingTo: nil) == .provider)
        #expect(AgentSetupFlow.stopped(runtime: "codex", job: failed, machine: leo) == "Codex did not sign in within 15 minutes.")
        // Codex again is the same install again, whose sign-in step gives a new code.
        #expect(AgentSetupFlow.start(chosen: "codex", runtime: "codex", job: failed, machine: leo) == .installAgain)
        #expect(AgentSetupFlow.start(chosen: "claude", runtime: "codex", job: failed, machine: leo) == .prepare)
    }

    /// An install that could not reach the internet says so in plain words, and names its server: the hub's own
    /// line with the system's code ("ETIMEDOUT") stays on the line's hover.
    @Test func anInstallThatCouldNotReachTheInternetSaysSoInPlainWords() throws {
        let failed = try job("failed", step: "runtime",
                             detail: "Codex did not install: npm could not reach the registry (ETIMEDOUT).")
        #expect(AgentSetupFlow.stopped(runtime: "codex", job: failed, machine: try machine())
                == "Codex did not install: vps could not reach the internet.")
        let other = try job("failed", step: "runtime", detail: "Codex did not install: the disk is full.")
        #expect(AgentSetupFlow.stopped(runtime: "codex", job: other, machine: try machine())
                == "Codex did not install: the disk is full.")
    }

    @Test func ivyGoesStraightToItsActivation() throws {
        let done = try job("done", runtime: "claude", agent: "ivy")
        let ivy = try machine(runtime: "claude", signedIn: true)
        #expect(AgentSetupFlow.page(runtime: "claude", job: done, machine: ivy, switchingTo: nil) == .activate)
        #expect(AgentSetupFlow.stopped(runtime: "claude", job: done, machine: ivy) == nil)
        #expect(AgentSetupFlow.start(chosen: "claude", runtime: "claude", job: done, machine: ivy) == .activate)
        // A reading that is not current says nothing about a sign-in.
        #expect(!AgentSetupFlow.signedIn(runtime: "claude", machine: try machine(runtime: "claude", signedIn: true, stale: true)))
    }

    @Test func whatTheHubDoesNowIsThePage() throws {
        let leo = try machine()
        #expect(AgentSetupFlow.page(runtime: "codex", job: try job("running", step: "runtime"), machine: leo, switchingTo: nil)
                == .installing(runtime: "codex"))
        #expect(AgentSetupFlow.page(runtime: "codex", job: try job("needs_owner"), machine: leo, switchingTo: nil)
                == .signIn(runtime: "codex"))
        // A sign-in on the machine itself, with no job: the sign-in page too.
        let signing = try machine(login: login("needs_owner"))
        #expect(AgentSetupFlow.page(runtime: "codex", job: nil, machine: signing, switchingTo: nil) == .signIn(runtime: "codex"))
        // An installed agent that is signed out, with nothing going on, starts with a sign-in on its machine.
        #expect(AgentSetupFlow.start(chosen: "codex", runtime: "codex", job: try job("done"), machine: leo) == .signIn)
    }

    /// **A signed-out agent always opens on both providers** (the owner, 4 November 2026: "if an agent is not
    /// connected, it should always have all the options!"): Claude Code installed on its machine and signed out, with
    /// nothing going on or stopped, is the provider page. A press on its checked card asks for its sign-in, and a press
    /// on the other one for the preparation of that provider.
    @Test func aSignedOutAgentWithItsProviderSetOpensOnBothProviders() throws {
        let manager = try machine(runtime: "claude")
        #expect(AgentSetupFlow.page(runtime: "claude", job: nil, machine: manager, switchingTo: nil) == .provider)
        #expect(AgentSetupFlow.page(runtime: "claude", job: try job("done", runtime: "claude"), machine: manager, switchingTo: nil)
                == .provider)
        #expect(AgentSetupFlow.start(chosen: "claude", runtime: "claude", job: nil, machine: manager) == .signIn)
        #expect(AgentSetupFlow.start(chosen: "codex", runtime: "claude", job: nil, machine: manager) == .prepare)
    }

    @Test func aFailedSignInOnTheMachineIsWhyItStopped() throws {
        let failed = try machine(login: login("failed", detail: "No code came back in 14 minutes. Start the sign-in again."))
        #expect(AgentSetupFlow.page(runtime: "codex", job: nil, machine: failed, switchingTo: nil) == .provider)
        #expect(AgentSetupFlow.stopped(runtime: "codex", job: nil, machine: failed) == "No code came back in 14 minutes.")
    }

    /// **A sign-in that only waited too long for him says nothing** (owner API 1.88, `timed_out`). The owner, 6 November
    /// 2026, on Iris's provider page, of "No code came back in 14 minutes." in orange under the two cards: "that orange
    /// message does not make sense for the user! what is that?!". The cards are the way to start again, so there is no
    /// line and no Try again; a failed install, or a sign-in that failed for a reason, keeps its line.
    @Test func aSignInThatOnlyWaitedTooLongForHimShowsNoLine() throws {
        var waited = login("failed", runtime: "claude", detail: "No code came back in 14 minutes. Start the sign-in again.")
        waited["timed_out"] = true
        let iris = try machine(runtime: "claude", login: waited)
        #expect(AgentSetupFlow.page(runtime: "claude", job: nil, machine: iris, switchingTo: nil) == .provider)
        #expect(AgentSetupFlow.stopped(runtime: "claude", job: nil, machine: iris) == nil)
        #expect(AgentSetupFlow.start(chosen: "claude", runtime: "claude", job: nil, machine: iris) == .signIn)
        // The sign-in step of an install that waited 15 minutes for him: no line either, and its card is the same
        // install again, whose sign-in step gives him a new code.
        let install = try job("failed", runtime: "claude", detail: "Claude Code did not sign in within 15 minutes. Try again in Founderizer.",
                              timedOut: true)
        #expect(AgentSetupFlow.stopped(runtime: "claude", job: install, machine: iris) == nil)
        #expect(AgentSetupFlow.start(chosen: "claude", runtime: "claude", job: install, machine: iris) == .installAgain)
        // A failed install says why, over its Try again (the page draws that button under this line only).
        let broken = try job("failed", runtime: "claude", step: "runtime", detail: "Claude Code did not install: the disk is full.",
                             timedOut: false)
        #expect(AgentSetupFlow.stopped(runtime: "claude", job: broken, machine: iris) == "Claude Code did not install: the disk is full.")
        // And a sign-in that failed for a reason is that reason, whatever the job says.
        let noLink = try machine(runtime: "claude", login: login("failed", runtime: "claude",
                                                                 detail: "Claude Code printed no sign-in link in 90 seconds. Try again."))
        #expect(AgentSetupFlow.stopped(runtime: "claude", job: install, machine: noLink) == "Claude Code printed no sign-in link in 90 seconds.")
    }

    /// **His press on a card is his press to sign in** (the owner, 6 November 2026: "I clicked on Claude Code and then I
    /// have to click again on sign in? why? when I said claude code I wanted to sign in! we should save that click").
    /// Every press but the one that activates leads to his sign-in, now or after its install or preparation, and the
    /// provider's page then opens once, as soon as its link is there. A sign-in that he did not start on this visit
    /// keeps its Sign in button.
    @Test func aPressOnACardOpensTheSignInPageWithoutASecondPress() throws {
        let leo = try machine()
        let link = URL(string: "https://claude.ai/oauth/authorize?code=1")
        #expect(AgentSetupFlow.start(chosen: "codex", runtime: "codex", job: nil, machine: leo).signsIn)          // .signIn
        #expect(AgentSetupFlow.start(chosen: "codex", runtime: "codex", job: try job("failed", detail: expired),
                                     machine: leo).signsIn)                                                         // .installAgain
        #expect(AgentSetupFlow.start(chosen: "claude", runtime: "codex", job: nil, machine: leo).signsIn)         // .prepare
        let ivy = try machine(runtime: "claude", signedIn: true)
        #expect(!AgentSetupFlow.start(chosen: "claude", runtime: "claude", job: nil, machine: ivy).signsIn)       // .activate
        // Once his press asked for it, the page opens when the link is there, and only until it is open.
        #expect(AgentSetupFlow.opensByItself(askedHere: true, opened: false, link: link))
        #expect(!AgentSetupFlow.opensByItself(askedHere: true, opened: false, link: nil))
        #expect(!AgentSetupFlow.opensByItself(askedHere: true, opened: true, link: link))
        // A sign-in that he did not ask for here opens only by his press on Sign in.
        #expect(!AgentSetupFlow.opensByItself(askedHere: false, opened: false, link: link))
    }

    @Test func theOtherProviderIsPreparedThenSwitchedThenLoaded() throws {
        let leo = try machine()
        // Preparing Claude Code on the server, and its sign-in.
        #expect(AgentSetupFlow.page(runtime: "codex", job: try job("running", kind: "prepare", runtime: "claude", step: "runtime"),
                                    machine: leo, switchingTo: "claude") == .installing(runtime: "claude"))
        #expect(AgentSetupFlow.page(runtime: "codex", job: try job("needs_owner", kind: "prepare", runtime: "claude"),
                                    machine: leo, switchingTo: "claude") == .signIn(runtime: "claude"))
        // Prepared: the switch, then the agent loading it.
        let prepared = try job("done", kind: "prepare", runtime: "claude")
        #expect(AgentSetupFlow.page(runtime: "codex", job: prepared, machine: leo, switchingTo: "claude") == .switching(runtime: "claude"))
        #expect(AgentSetupFlow.page(runtime: "claude", job: prepared, machine: try machine(pending: true), switchingTo: "claude")
                == .switching(runtime: "claude"))
        let loaded = try machine(runtime: "claude", signedIn: true)
        #expect(AgentSetupFlow.page(runtime: "claude", job: prepared, machine: loaded, switchingTo: "claude") == .activate)
        // A preparation that failed is back at the providers, with its reason.
        let stopped = try job("failed", kind: "prepare", runtime: "claude", step: "runtime", detail: "The install failed.")
        #expect(AgentSetupFlow.page(runtime: "codex", job: stopped, machine: leo, switchingTo: "claude") == .provider)
        #expect(AgentSetupFlow.stopped(runtime: "codex", job: stopped, machine: leo) == "The install failed.")
    }

    @Test func anotherAgentsJobIsNotThisOnes() throws {
        let server = try JSONDecoder().decode(ServerEntry.self, from: json([
            "name": "vps", "kind": "linux", "address": "100.96.100.130", "user": "fleet", "hub": false, "joined": true,
            "agents": ["leo"], "available": false, "why": ["has_agent"],
            "job": ["id": 9, "kind": "install", "agent": "scout", "runtime": "codex", "state": "running", "step": "user",
                    "detail": NSNull(), "prompt": NSNull(), "created": 1, "updated": 2],
        ] as [String: Any]))
        #expect(AgentSetupFlow.job(of: "leo", on: server) == nil)
        #expect(AgentSetupFlow.job(of: "scout", on: server)?.id == 9)
    }

    @Test func anActiveAgentsFinishedInstallIsHistory() throws {
        let server = try JSONDecoder().decode(ServerEntry.self, from: json([
            "name": "vps", "kind": "linux", "address": "100.96.100.130", "user": "fleet", "hub": false, "joined": true,
            "agents": ["leo"], "available": false, "why": ["has_agent"],
            "job": ["id": 4, "kind": "install", "agent": "leo", "runtime": "codex", "state": "failed", "step": "sign_in",
                    "detail": "Codex did not sign in within 15 minutes. Try again in Fleet.", "prompt": NSNull(),
                    "created": 1, "updated": 2],
        ] as [String: Any]))
        #expect(AgentSetupFlow.job(of: "leo", on: server)?.id == 4)                 // in setup: the same install again
        #expect(AgentSetupFlow.job(of: "leo", on: server, active: true) == nil)     // active: only its sign-in
    }

    @Test func theSetupReplacesTheChatOnlyOfAnAgentThatIsNotActive() throws {
        func agent(_ active: Bool?) throws -> FleetAgent {
            try JSONDecoder().decode(FleetAgent.self, from: json([
                "name": "leo", "role": "worker", "runtime": "codex", "active": active.map { $0 as Any } ?? NSNull(), "can": ["shell"],
            ] as [String: Any]))
        }
        let all = AgentSetupFlow.features
        #expect(AgentSetupFlow.shows(try agent(false), features: all))
        #expect(!AgentSetupFlow.shows(try agent(true), features: all))
        #expect(!AgentSetupFlow.shows(try agent(nil), features: all))
        #expect(!AgentSetupFlow.shows(try agent(false), features: all.filter { $0 != "machine_signin" }))
    }

    @Test func anActiveAgentShowsItsSetupOnlyWhileItsMachineReportsItSignedOut() throws {
        func agent(_ signedIn: Bool?, runtime: String = "claude") throws -> FleetAgent {
            try JSONDecoder().decode(FleetAgent.self, from: json([
                "name": "manager", "role": "manager", "runtime": runtime, "active": true, "can": ["shell"],
                "signed_in": signedIn.map { $0 as Any } ?? NSNull(),
            ] as [String: Any]))
        }
        let all = AgentSetupFlow.features
        #expect(AgentSetupFlow.shows(try agent(false), features: all))
        #expect(!AgentSetupFlow.shows(try agent(true), features: all))
        #expect(!AgentSetupFlow.shows(try agent(nil), features: all))           // an old reading, or an older hub
        #expect(!AgentSetupFlow.shows(try agent(false, runtime: "grok"), features: all))
    }

    /// The agent being added fills the window through its setup and its "Setting up", until its chat opens; an agent
    /// that ran before, deactivated or signed out, keeps its setup in its own page (the owner's yes of 12 November 2026).
    @Test func onlyTheAgentBeingAddedFillsTheWindow() throws {
        func leo(active: Bool, signedIn: Bool?, ready: Bool? = nil) throws -> FleetAgent {
            try JSONDecoder().decode(FleetAgent.self, from: json([
                "name": "leo", "role": "worker", "runtime": "claude", "active": active, "can": ["shell"],
                "signed_in": signedIn.map { $0 as Any } ?? NSNull(), "last_seen": 995,
                "chat_ready": ready.map { $0 as Any } ?? NSNull(),
            ] as [String: Any]))
        }
        func fills(_ agent: FleetAgent?, adding: Bool) -> Bool {
            AgentSetupFlow.fillsWindow(agent, adding: adding, features: AgentSetupFlow.features, serverTime: 1_000, fresh: true)
        }
        #expect(fills(try leo(active: false, signedIn: false), adding: true))                // its setup
        #expect(fills(try leo(active: true, signedIn: true, ready: false), adding: true))    // its "Setting up"
        #expect(!fills(try leo(active: true, signedIn: true, ready: true), adding: true))    // its chat
        #expect(!fills(try leo(active: false, signedIn: true), adding: false))               // deactivated
        #expect(!fills(try leo(active: true, signedIn: false), adding: false))               // signed out
        #expect(!fills(nil, adding: true))
        // An old reading holds the window for the agent being added, and only for it.
        let old = try leo(active: true, signedIn: true, ready: false)
        #expect(AgentSetupFlow.fillsWindow(old, adding: true, features: AgentSetupFlow.features, serverTime: 1_000, fresh: false))
        #expect(!AgentSetupFlow.fillsWindow(old, adding: false, features: AgentSetupFlow.features, serverTime: 1_000, fresh: false))
    }

    /// Adding ends once its setup is over and its chat can answer, or once the hub no longer lists it.
    @Test func addingEndsWhenItsChatCanAnswer() throws {
        func leo(active: Bool, ready: Bool?) throws -> FleetAgent {
            try JSONDecoder().decode(FleetAgent.self, from: json([
                "name": "leo", "role": "worker", "runtime": "claude", "active": active, "can": ["shell"],
                "signed_in": true, "chat_ready": ready.map { $0 as Any } ?? NSNull(),
            ] as [String: Any]))
        }
        let all = AgentSetupFlow.features
        #expect(!AgentSetupFlow.addingEnds(try leo(active: false, ready: nil), features: all))     // its setup shows
        #expect(!AgentSetupFlow.addingEnds(try leo(active: true, ready: false), features: all))    // "Setting up"
        #expect(AgentSetupFlow.addingEnds(try leo(active: true, ready: true), features: all))      // its chat
        #expect(AgentSetupFlow.addingEnds(try leo(active: true, ready: nil), features: all))       // an older hub
        #expect(AgentSetupFlow.addingEnds(nil, features: all))                                     // deleted
    }

    /// Leo, 26 October 2026: activated, then "Hi", and 27 seconds of "Thinking" while its chat session started.
    @Test func settingUpTakesThePlaceOfAChatThatCannotAnswerYet() throws {
        func leo(_ ready: Bool?, seen: Double = 995, limited: Bool = false) throws -> FleetAgent {
            var fields: [String: Any] = ["name": "leo", "role": "worker", "runtime": "claude", "active": true,
                                         "can": ["shell"], "signed_in": true, "last_seen": seen,
                                         "chat_ready": ready.map { $0 as Any } ?? NSNull()]
            if limited { fields["limit"] = ["since": 900, "until": 2_000, "reset_known": true, "task": NSNull()] }
            return try JSONDecoder().decode(FleetAgent.self, from: json(fields))
        }
        #expect(AgentSetupFlow.chatStarts(try leo(false), serverTime: 1_000, fresh: true))
        #expect(!AgentSetupFlow.chatStarts(try leo(true), serverTime: 1_000, fresh: true))
        #expect(!AgentSetupFlow.chatStarts(try leo(nil), serverTime: 1_000, fresh: true))       // an older hub or helper
        #expect(!AgentSetupFlow.chatStarts(try leo(false), serverTime: 1_000, fresh: false))    // an old reading
        #expect(!AgentSetupFlow.chatStarts(try leo(false, seen: 800), serverTime: 1_000, fresh: true))  // offline
        #expect(!AgentSetupFlow.chatStarts(try leo(false, limited: true), serverTime: 1_000, fresh: true))
        #expect(!AgentSetupFlow.chatStarts(nil, serverTime: 1_000, fresh: true))
    }

    @Test func theCheckItemThatStandsInTheWayIsOneLine() throws {
        let result = try JSONDecoder().decode(MachineVerification.self, from: json([
            "check": 3, "checked_at": 10_000, "revision": "abc",
            "items": [["kind": "capability", "ref": "browser", "state": "failed", "detail": "No Chrome.", "required": false],
                      ["kind": "runtime", "ref": "runtime_signed_in", "state": "failed", "detail": "Codex is signed out.",
                       "required": true]],
        ] as [String: Any]))
        #expect(AgentSetupFlow.blocker(result) == "Runtime Signed In: Codex is signed out.")
        #expect(AgentSetupFlow.blocker(nil) == nil)
    }

    // **The install's title says the step that runs** (the owner, 13 November 2026: "show some sort of progress bar
    // there, otherwise it looks stuck! Same thing for other long actions where we actually know the progress").

    @Test func anInstallThatRunsCountsItsStepOfTheServersFive() throws {
        let steps = ["user", "runtime", "checkout", "service", "sign_in"]
        for (index, step) in steps.enumerated() {
            let count = AgentSetupFlow.installCount(try job("running", step: step), onMac: false)
            #expect(count?.step == index + 1)
            #expect(count?.of == 5)
        }
        #expect(AgentSetupFlow.installing("Codex", on: "app-1", job: try job("running", step: "runtime"), onMac: false)
                == "Installing Codex on app-1 · 2 of 5")
    }

    @Test func aMacHasNoUserStepSoItsInstallHasFour() throws {
        let checkout = try job("running", step: "checkout")
        #expect(AgentSetupFlow.installCount(checkout, onMac: true)?.step == 2)
        #expect(AgentSetupFlow.installCount(checkout, onMac: true)?.of == 4)
        #expect(AgentSetupFlow.installing("Claude Code", on: "mac-1", job: checkout, onMac: true)
                == "Installing Claude Code on mac-1 · 2 of 4")
        // A step that a Mac's list does not hold gets no number.
        #expect(AgentSetupFlow.installCount(try job("running", step: "user"), onMac: true) == nil)
    }

    @Test func aPreparationCountsItsTwoSteps() throws {
        let signIn = try job("running", kind: "prepare", runtime: "claude", step: "sign_in")
        #expect(AgentSetupFlow.installCount(signIn, onMac: false)?.step == 2)
        #expect(AgentSetupFlow.installCount(signIn, onMac: false)?.of == 2)
    }

    @Test func aTitleShowsNoNumberThatTheAppDoesNotHave() throws {
        let plain = "Installing Codex on app-1"
        // No job, a job in the queue, and a running job that has reported no step yet.
        #expect(AgentSetupFlow.installing("Codex", on: "app-1", job: nil, onMac: false) == plain)
        #expect(AgentSetupFlow.installing("Codex", on: "app-1", job: try job("queued", step: nil), onMac: false) == plain)
        #expect(AgentSetupFlow.installing("Codex", on: "app-1", job: try job("running", step: nil), onMac: false) == plain)
        // A step that the list does not hold, from a newer server.
        #expect(AgentSetupFlow.installing("Codex", on: "app-1", job: try job("running", step: "warm_up"), onMac: false) == plain)
        // A job of another kind has other steps: a rename moves the checkout and the service only.
        #expect(AgentSetupFlow.installing("Codex", on: "app-1", job: try job("running", kind: "rename", step: "service"),
                                          onMac: false) == plain)
        #expect(AgentSetupFlow.installCount(try job("running", kind: "remove", step: "service"), onMac: false) == nil)
        // A job that waits for him or that ended is no wait of the machine.
        for state in ["needs_owner", "failed", "done", "canceled"] {
            #expect(AgentSetupFlow.installCount(try job(state, step: "sign_in"), onMac: false) == nil)
        }
    }
}

/// **The manager of a new fleet gets its server in its own setup** (hub feature `manager_server`, UI-API.md 1.82): the
/// first `team.json` of `hub.sh` gives it `"placed": false`, its machine reports nothing and it is active from the
/// start. Synthetic data only.
struct ManagerServerTests {
    private let all = AgentSetupFlow.features + [AgentSetupFlow.serverFeature]

    private func manager(placed: Bool? = false, signedIn: Bool? = nil, alive: String? = nil) throws -> FleetAgent {
        var fields: [String: Any] = ["name": "manager", "role": "manager", "runtime": "claude", "active": true, "can": [],
                                     "signed_in": signedIn.map { $0 as Any } ?? NSNull(),
                                     "chat_ready": NSNull(), "alive": alive.map { $0 as Any } ?? NSNull()]
        if let placed { fields["placed"] = placed }
        return try JSONDecoder().decode(FleetAgent.self, from: json(fields))
    }

    @Test func aHubThatSaysNothingOfItGivesEveryAgentAServer() throws {
        #expect(try manager(placed: nil).placed)
        #expect(!(try manager(placed: false).placed))
        #expect(try manager(placed: true).placed)
    }

    @Test func itsSetupShowsWhileItHasNoServer() throws {
        #expect(AgentSetupFlow.shows(try manager(), features: all))
        // A hub without the feature shows what it shows today: an active manager that reports nothing keeps its chat.
        #expect(!AgentSetupFlow.shows(try manager(), features: AgentSetupFlow.features))
        #expect(!AgentSetupFlow.shows(try manager(), features: all.filter { $0 != "machine_signin" }))
    }

    /// From the press that gave it its server to its first session: its install, its sign-in and "Setting up".
    @Test func itsSetupGoesOnAfterThePressUntilItRuns() throws {
        func shows(_ agent: FleetAgent) -> Bool { AgentSetupFlow.shows(agent, features: all, placing: true) }
        #expect(shows(try manager(placed: true)))                                       // its server installs it
        #expect(shows(try manager(placed: true, signedIn: false, alive: "manager")))     // its session waits for the sign-in
        #expect(shows(try manager(placed: true, signedIn: true)))                       // signed in, no session yet
        #expect(shows(try manager(placed: true, signedIn: true, alive: "owner-chat")))
        #expect(!shows(try manager(placed: true, signedIn: true, alive: "owner-chat,manager")))
        #expect(AgentSetupFlow.runs(try manager(placed: true, signedIn: true, alive: "manager")))
        #expect(!AgentSetupFlow.runs(try manager(placed: false, signedIn: true, alive: "manager")))
    }

    /// Its setup fills the window while it gets its first server, until it runs; once it had one, a sign-out keeps its
    /// page.
    @Test func itsSetupFillsTheWindowUntilItRuns() throws {
        func fills(_ agent: FleetAgent, features: [String], placing: Bool = false) -> Bool {
            AgentSetupFlow.fillsWindow(agent, adding: false, features: features, placing: placing, serverTime: 1_000, fresh: true)
        }
        #expect(fills(try manager(), features: all))
        #expect(fills(try manager(placed: true, signedIn: true), features: all, placing: true))
        #expect(!fills(try manager(placed: true, signedIn: false), features: all))
        #expect(!fills(try manager(), features: AgentSetupFlow.features))
    }

    /// A manager that this Mac never saw without a server is any fleet's manager: a session that starts again, or a
    /// reading that is old, keeps its chat.
    @Test func aManagerThatHadAServerKeepsItsChat() throws {
        #expect(!AgentSetupFlow.shows(try manager(placed: true, signedIn: true), features: all))
        #expect(!AgentSetupFlow.shows(try manager(placed: true), features: all))
        #expect(AgentSetupFlow.shows(try manager(placed: true, signedIn: false), features: all))      // signed out, as today
    }

    @Test func itGoesOnlyOnAServerThatTheHubOffersAndThatHasNoAgent() throws {
        func server(_ name: String, agents: [String], available: Bool, hub: Bool = false) -> [String: Any] {
            ["name": name, "kind": "linux", "address": NSNull(), "user": "fleet", "hub": hub, "joined": true, "agents": agents,
             "available": available, "why": available ? [] : ["no_reading"], "job": NSNull()]
        }
        let list = try JSONDecoder().decode(ServerList.self, from: json([
            "db": "db", "time": 1_000, "desired_revision": NSNull(), "join": NSNull(),
            "servers": [server("hub", agents: [], available: false, hub: true), server("box", agents: ["scout"], available: true),
                        server("vps-2", agents: [], available: true), server("vps-3", agents: [], available: false)],
        ] as [String: Any]))
        #expect(list.servers.filter(AgentSetupFlow.isFree).map(\.name) == ["vps-2"])
    }

    @Test func thePressSendsTheServerAndTheProviderAgainstTheTeamItRead() async throws {
        let base = String(repeating: "a", count: 64), id = UUID()
        let hub = try OneAnswer(status: "200 OK") { _ in
            #"{"ok":true,"request_id":"\#(id.uuidString.lowercased())","client":"test","replayed":false,"agent":"manager","#
                + #""server":"vps-2","was":null,"runtime":"codex","job":3,"revision":"\#(String(repeating: "c", count: 40))","#
                + #""sha256":"\#(String(repeating: "d", count: 64))"}"#
        }
        let receipt = try await HubClient().moveAgent(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db",
                                                      client: "test", requestID: id, agent: "manager", sha256: base,
                                                      server: "vps-2", runtime: "codex")
        #expect(receipt.was == nil && receipt.runtime == "codex" && receipt.job == 3)
        #expect(hub.received.starts(with: Data("POST /ui/team/agents/manager/move HTTP/1.1\r\n".utf8)))
        let body = try #require(try JSONSerialization.jsonObject(with: OneAnswer.body(of: hub.received)) as? [String: String])
        #expect(body == ["base_sha256": base, "server": "vps-2", "runtime": "codex", "db": "db",
                         "request_id": id.uuidString.lowercased()])
    }

    @Test func aReceiptOfAnotherServerOrProviderIsNotTaken() async throws {
        let id = UUID()
        let hub = try OneAnswer(status: "200 OK") { _ in
            #"{"ok":true,"request_id":"\#(id.uuidString.lowercased())","agent":"manager","server":"vps-2","was":null,"#
                + #""runtime":"claude","job":3,"revision":"r","sha256":"s"}"#
        }
        await #expect(throws: HubError.self) {
            try await HubClient().moveAgent(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db", client: "test",
                                            requestID: id, agent: "manager", sha256: String(repeating: "a", count: 64),
                                            server: "vps-2", runtime: "codex")
        }
        await #expect(throws: HubError.self) {      // a provider the hub would refuse never leaves this Mac
            try await HubClient().moveAgent(hub: URL(string: "http://127.0.0.1:1")!, database: "db", client: "test",
                                            agent: "manager", sha256: String(repeating: "a", count: 64), server: "vps-2",
                                            runtime: "grok")
        }
    }
}
