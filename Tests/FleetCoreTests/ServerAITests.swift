import Foundation
import Testing
@testable import FleetCore

/// The owner's one choice of AI for a new server, and what its server's page says about each provider.
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

    private func reading(desktop: String?, needs: String?, runtimes: String = "{}") throws -> MachineStatus {
        let json = """
        {"agent": "juno", "machine": "mini", "role": "worker", "update": {"state": "current"},
         "security": \(desktop.map { "{\"desktop\": \($0)}" } ?? "{}"), \(needs.map { "\"needs\": \($0)," } ?? "")
         "runtime": {"name": "claude", "version": "2.1", "signed_in": true}, "os": {}, "runtimes": \(runtimes)}
        """
        return try JSONDecoder().decode(MachineStatus.self, from: Data(json.utf8))
    }

    private let macClaude = "{\"chatgpt\": false, \"browser\": true}"
    private let macBoth = "{\"chatgpt\": true, \"browser\": true}"
    private let needsClaude = "{\"browser\": true, \"chatgpt\": false}"
    private let needsBoth = "{\"browser\": true, \"chatgpt\": true}"

    private func runtime(_ version: String?, _ signedIn: Bool?) throws -> MachineStatus.Runtime {
        try JSONDecoder().decode(MachineStatus.Runtime.self, from: JSONSerialization.data(withJSONObject: [
            "name": "x", "version": version as Any, "signed_in": signedIn as Any]))
    }

    @Test func aProviderNobodyChoseIsNoFault() throws {
        let row = ProviderRow(name: "codex", runtime: try runtime(nil, nil), reading: try reading(desktop: macClaude, needs: needsClaude))
        #expect(row.title == "ChatGPT")
        #expect(row.answer == .notSetUp("Not set up. Open the installer on that Mac."))
    }

    @Test func aMacWithBothReadsChatGPTFromTheAppAndNotTheTerminalCopy() throws {
        let row = ProviderRow(name: "codex", runtime: try runtime(nil, nil), reading: try reading(desktop: macBoth, needs: needsBoth))
        #expect(row.answer == .mark(.good, words: "Signed in", whoActs: nil))
    }

    @Test func aRealSignOutIsAFault() throws {
        let row = ProviderRow(name: "codex", runtime: try runtime(nil, nil), reading: try reading(desktop: macClaude, needs: needsBoth))
        #expect(row.answer == .mark(.bad, words: "Not signed in", whoActs: "Open the installer on that Mac."))
    }

    @Test func aLinuxServerStaysOnItsOwnSignIn() throws {
        let row = ProviderRow(name: "claude", runtime: try runtime("2.1", false), reading: try reading(desktop: nil, needs: needsClaude))
        #expect(row.title == "Claude Code")
        #expect(row.answer == .mark(.bad, words: "2.1 · Not signed in", whoActs: "Signing in is your own step: the Sign in card below takes it."))
        let other = ProviderRow(name: "codex", runtime: try runtime(nil, nil), reading: try reading(desktop: nil, needs: needsClaude))
        #expect(other.answer == .notSetUp("Not set up"))
    }

    @Test func aHubFromBeforeTheChoiceKeepsItsCross() throws {
        let row = ProviderRow(name: "codex", runtime: try runtime(nil, nil), reading: try reading(desktop: nil, needs: nil))
        guard case .mark(.bad, _, _) = row.answer else { Issue.record("no cross"); return }
    }

    @Test func aNewInstallerSaysThatItTakesTheChoice() throws {
        #expect(MacInstallState(state: "waiting", says: "x").choice == true)
        let old = try JSONDecoder().decode(MacInstallState.self, from: Data("{\"state\":\"waiting\",\"says\":\"x\",\"steps\":[]}".utf8))
        #expect(old.choice == nil)
    }
}
