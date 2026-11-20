import Foundation
import Testing
@testable import FleetCore

/// The owner's one choice of AI for a new server, and what a Mac's page says while Codex of its screen tasks cannot run.
struct ServerAITests {
    @Test func eachChoiceIsARuntimeAndASignInOfChatGPT() {
        #expect(ServerAI.claude.runtime == "claude" && !ServerAI.claude.hasChatGPT)
        #expect(ServerAI.chatGPT.runtime == "codex" && ServerAI.chatGPT.hasChatGPT)
        #expect(ServerAI.both.runtime == "claude" && ServerAI.both.hasChatGPT)
        #expect(ServerAI.linuxChoices == [.claude, .chatGPT])
    }

    @Test func theChoiceNeedsAHubThatKeepsIt() {
        #expect(Servers.choosesAI(["server_ai_choice"]))
        #expect(!Servers.choosesAI(["mac_setup"]))
        #expect(!Servers.choosesAI(nil))
    }

    /// `screen`: the agent has a screen runtime, as its helper says it in `settings.screen`.
    private func reading(desktop: String?, needs: String?, runtimes: String = "{}", agent: String = "juno",
                         own: String = "claude", ownSignedIn: Bool = true, screen: Bool = false,
                         reportedAt: Double = 1000, login: String = "null") throws -> MachineStatus {
        let json = """
        {"agent": "\(agent)", "machine": "mini", "role": "worker", "update": {"state": "current"},
         "security": \(desktop.map { "{\"desktop\": \($0)}" } ?? "{}"), \(needs.map { "\"needs\": \($0)," } ?? "")
         "runtime": {"name": "\(own)", "version": "2.1", "signed_in": \(ownSignedIn)}, "os": {}, "runtimes": \(runtimes),
         "settings": {"model": null, "effort": null, "can": ["shell"],
                      "screen": \(screen ? "{\"model\": null, \"effort\": null}" : "null")},
         "reported_at": \(reportedAt), "login": \(login)}
        """
        return try JSONDecoder().decode(MachineStatus.self, from: Data(json.utf8))
    }

    /// A Mac with its own reading, read at `readAt`.
    private func mac(agents: [String] = ["juno", "nova"], readAt: Double = 1000) throws -> ServerEntry {
        try JSONDecoder().decode(ServerEntry.self, from: Data("""
        {"name": "mini", "kind": "mac", "hub": false, "joined": true, "available": true, "why": [],
         "agents": [\(agents.map { "\"\($0)\"" }.joined(separator: ", "))],
         "reading": {"source": "server", "os": {}, "runtimes": {}, "reported_at": \(readAt), "stale": false}}
        """.utf8))
    }

    private func signIn(_ runtime: String, _ state: String, at: Double = 1, timedOut: Bool = false) -> String {
        "{\"id\": 7, \"runtime\": \"\(runtime)\", \"state\": \"\(state)\", \"detail\": null, \"started_at\": 1,"
            + " \"updated_at\": \(at), \"url\": null, \"shows_code\": null, \"wants_code\": false, \"timed_out\": \(timedOut)}"
    }

    private let macClaude = "{\"chatgpt\": false, \"browser\": true}"
    private let macWithApp = "{\"chatgpt\": false, \"chatgpt_app\": true, \"browser\": true}"
    private let macNoApp = "{\"chatgpt\": false, \"chatgpt_app\": false, \"browser\": true}"
    private let codexOut = "{\"codex\": {\"version\": null, \"signed_in\": false}}"
    private let codexIn = "{\"codex\": {\"version\": null, \"signed_in\": true}}"
    private let needsClaude = "{\"browser\": true, \"chatgpt\": false}"
    private let needsBoth = "{\"browser\": true, \"chatgpt\": true}"

    /// The page of a Mac says it while Codex of its screen tasks cannot run, and names the route that puts it right
    /// (the owner's "Yes, both rows" of 19 November 2026). Fails when the page offers a sign-in on a Mac with no
    /// ChatGPT app, sends the owner to the installer for a sign-in that ended, or shows a row on a Mac that is well.
    @Test func aMacsPageHasTheSignInOfCodexOrNamesTheInstaller() throws {
        let mini = try mac()
        func juno(_ runtimes: String, _ desktop: String) throws -> MachineStatus {
            try reading(desktop: desktop, needs: needsBoth, runtimes: runtimes, screen: true)
        }
        // A sign-in that ended, or a sign-out: the app is there, or the Mac does not say, and the agent says signed out.
        #expect(try mini.screenSignIn([juno(codexOut, macWithApp)], at: 1000) == .signIn(agent: "juno"))
        #expect(try mini.screenSignIn([juno(codexOut, macClaude)], at: 1000) == .signIn(agent: "juno"))
        // No ChatGPT app: a sign-in does not help there, whatever a `codex` program of the Mac's own says. Only a
        // current reading of the Mac says it: an old one can be from before the installer brought the app.
        #expect(try mini.screenSignIn([juno(codexOut, macNoApp)], at: 1000) == .noApp)
        #expect(try mac(readAt: 100).screenSignIn([juno(codexOut, macNoApp)], at: 1000) == nil)
        #expect(ScreenSignIn.notInstalled == "Not installed. Open the installer on that Mac.")
        // The agent says signed in while the Mac's own reading still says no, for up to five minutes: no row, because
        // the sign-in page would say "Codex is signed in".
        #expect(try mini.screenSignIn([juno(codexIn, macWithApp)], at: 1000) == nil)
        // A Mac that needs no ChatGPT, a Linux server, and a reading of another server's agent.
        #expect(try mini.screenSignIn([reading(desktop: macNoApp, needs: needsClaude, runtimes: codexOut, screen: true)], at: 1000) == nil)
        #expect(try mini.screenSignIn([reading(desktop: nil, needs: needsBoth, runtimes: codexOut, screen: true)], at: 1000) == nil)
        #expect(try mac(agents: ["solo"]).screenSignIn([juno(codexOut, macWithApp)], at: 1000) == nil)
    }

    /// One sign-in of Codex serves each agent of a Mac's user, so the page reads its agents together. Fails when the
    /// page shows a row that no screen task needs, a second sign-in beside one that runs or waits, a row from a reading
    /// that is older than a sign-in that worked, or no usable sign-in while an agent that is off says "signed out".
    @Test func theAgentsOfOneMacShareOneSignInOfCodex() throws {
        let mini = try mac()
        func agent(_ name: String, _ runtimes: String, screen: Bool = true, own: String = "claude", ownSignedIn: Bool = true,
                   at: Double = 1000, login: String = "null", desktop: String? = nil) throws -> MachineStatus {
            try reading(desktop: desktop ?? macWithApp, needs: needsBoth, runtimes: runtimes, agent: name, own: own,
                        ownSignedIn: ownSignedIn, screen: screen, reportedAt: at, login: login)
        }
        // No agent of the Mac has a screen runtime: no screen task can exist, so the page names no missing app.
        #expect(try mini.screenSignIn([agent("juno", codexOut, screen: false, desktop: macNoApp)], at: 1000) == nil)
        // An agent with no screen runtime reads a `codex` program that no screen task runs.
        #expect(try mini.screenSignIn([agent("juno", codexOut, screen: false), agent("nova", codexIn)], at: 1000) == nil)
        // Only a current reading says it, and the first agent with one gets the sign-in.
        #expect(try mini.screenSignIn([agent("juno", codexOut)], at: 5000) == nil)
        #expect(try mini.screenSignIn([agent("juno", codexOut), agent("nova", codexOut, at: 5000)], at: 5000) == .signIn(agent: "nova"))
        // An agent whose own provider is Codex waits for its own sign-in: its card is there, and no second one. An
        // old reading of such an agent hides nothing: its own card cannot be pressed.
        let own = try agent("nova", codexOut, own: "codex", ownSignedIn: false)
        #expect(!own.screenCodexSignedOut)
        #expect(try mini.screenSignIn([agent("juno", codexOut), own], at: 1000) == nil)
        #expect(try mini.screenSignIn([agent("juno", codexOut, at: 5000), own], at: 5000) == .signIn(agent: "juno"))
        // A sign-in of Codex that runs for the second agent, from a task's row: the row is that one, and no new one.
        let going = try agent("nova", codexOut, login: signIn("codex", "needs_owner"))
        #expect(try mini.screenSignIn([agent("juno", codexOut), going], at: 1000) == .signIn(agent: "nova"))
        // An agent with a sign-in of its own provider that runs is passed over: its sign-in page shows that one.
        let busy = try agent("juno", codexOut, login: signIn("claude", "needs_owner"))
        #expect(mini.screenSignIn([busy], at: 1000) == nil)
        #expect(try mini.screenSignIn([busy, agent("nova", codexOut)], at: 1000) == .signIn(agent: "nova"))
        // After a sign-in that ended well through one agent, the reading of the other from before that end says
        // nothing of now; its next reading does.
        let done = try agent("juno", codexIn, login: signIn("codex", "done", at: 1000))
        #expect(try mini.screenSignIn([done, agent("nova", codexOut, at: 990)], at: 1001) == nil)
        #expect(try mini.screenSignIn([done, agent("nova", codexOut, at: 1001)], at: 1001) == .signIn(agent: "nova"))
        // The hub says when it ended, also on the row of an agent whose own reading is old.
        let doneAndOff = try agent("juno", codexIn, at: 100, login: signIn("codex", "done", at: 1000))
        #expect(try mini.screenSignIn([doneAndOff, agent("nova", codexOut, at: 990)], at: 1001) == nil)
        // A sign-in that failed ended nothing: its agent is the row, before the first agent, with its line and Try again.
        let failed = try agent("nova", codexOut, at: 990, login: signIn("codex", "failed", at: 1000))
        #expect(failed.signInLine(working: false, of: "codex")?.warn == true)
        #expect(try mini.screenSignIn([agent("juno", codexOut), failed], at: 1001) == .signIn(agent: "nova"))
        // Not one that only waited too long for the owner, which is no news, and not one from before a sign-in that
        // ended well: the provider ended that one later, and the old failure is history.
        let waited = try agent("nova", codexOut, at: 990, login: signIn("codex", "failed", at: 1000, timedOut: true))
        #expect(try mini.screenSignIn([agent("juno", codexOut), waited], at: 1001) == .signIn(agent: "juno"))
        let earlier = try agent("nova", codexOut, at: 3000, login: signIn("codex", "failed", at: 1000))
        let later = try agent("juno", codexOut, at: 3000, login: signIn("codex", "done", at: 2000))
        #expect(mini.screenSignIn([later, earlier], at: 3001) == .signIn(agent: "juno"))
    }

    @Test func aNewInstallerSaysThatItTakesTheChoice() throws {
        #expect(MacInstallState(state: "waiting", says: "x").choice == true)
        let old = try JSONDecoder().decode(MacInstallState.self, from: Data("{\"state\":\"waiting\",\"says\":\"x\",\"steps\":[]}".utf8))
        #expect(old.choice == nil)
    }
}
