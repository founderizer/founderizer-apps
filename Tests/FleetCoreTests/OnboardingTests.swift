import Foundation
import Testing
@testable import FleetCore

struct OnboardingTests {
    /// The bundled installer's one run since executor 2.0.0: a provider's setup for an existing agent.
    private func preparation() -> ServerConfiguration {
        var config = ServerConfiguration()
        config.hub = "http://100.96.10.20:8765"; config.prepareRuntime = "worker4"; config.runtime = "claude"
        config.generation = "g1"; config.machine = "worker4"
        return config
    }

    @Test func aProviderSetupIsTheOneRunWithTheAgreedArgumentsAndNoShellText() throws {
        let config = preparation()
        try config.validate()
        let agreed = ["run", "--json", "--auth", "agent", "--hub", "http://100.96.10.20:8765/", "--repo", "git://100.96.10.20/fleet-pilot.git",
                      "--prepare-runtime", "worker4", "--runtime", "claude", "--generation", "g1", "--machine", "worker4"]
        #expect(config.arguments == agreed)
        let sent = try JSONDecoder().decode(ServerConfiguration.self, from: JSONEncoder().encode(config))   // as the service gets it
        #expect(sent.arguments == agreed)
        let changes: [(inout ServerConfiguration) -> Void] = [
            { $0.prepareRuntime = nil }, { $0.auth = "password" }, { $0.auth = "identity" }, { $0.generation = nil },
            { $0.generation = "g 1" }, { $0.machine = nil }, { $0.machine = "bad host" }, { $0.machine = "-oProxyCommand=id" },
            { $0.prepareRuntime = "Worker4" }, { $0.prepareRuntime = "../x" }, { $0.runtime = "grok" }]
        for change in changes {
            var refused = config; change(&refused)
            #expect(throws: (any Error).self) { try refused.validate() }
        }
        // The form of a run that executor 2.0.0 removed (a new server by its address and SSH user) starts nothing.
        let removed = #"{"host":"server.example.com","port":22,"login":"root","name":"new-worker","runtime":"codex","resume":false,"auth":"agent","hub":"http://100.96.10.20:8765"}"#
        let old = try JSONDecoder().decode(ServerConfiguration.self, from: Data(removed.utf8))
        #expect(throws: SetupError.self) { try old.validate() }
        #expect(!String(decoding: try JSONEncoder().encode(config), as: UTF8.self).contains("password"))
    }

    @Test func theInstallerSaysWhetherItPreparesARuntime() throws {
        func executor(_ capabilities: String) throws -> SetupExecutor {
            try JSONDecoder().decode(SetupExecutor.self, from: Data(#"{"v":1,"type":"version","executor":"2.0.0","capabilities":\#(capabilities)}"#.utf8))
        }
        #expect(try executor(#"["prepare_runtime"]"#).supportsRuntimePreparation)
        #expect(try executor(#"["existing_machine","prepare_runtime"]"#).supportsRuntimePreparation)     // executor 1.3
        #expect(try !executor(#"["existing_machine"]"#).supportsRuntimePreparation)
        let other = try JSONDecoder().decode(SetupExecutor.self, from: Data(#"{"v":2,"type":"version","executor":"3.0.0","capabilities":["prepare_runtime"]}"#.utf8))
        #expect(!other.supportsRuntimePreparation)
        let current = try executor(#"["prepare_runtime"]"#)
        #expect(try JSONDecoder().decode(SetupExecutor.self, from: JSONEncoder().encode(current)) == current)   // the helper's checked copy
    }

    @Test func protocolBindsRunAndSequenceAndTerminalState() throws {
        func event(_ fields: String) throws -> SetupEvent {
            try JSONDecoder().decode(SetupEvent.self, from: Data(fields.utf8))
        }
        var timeline = SetupTimeline()
        let first = try event(#"{"v":1,"run":"one","seq":1,"type":"step","id":"runtime_login","title":"Sign in the runtime","status":"running"}"#)
        try timeline.append(first)
        #expect(throws: SetupError.self) { try timeline.append(first) }
        #expect(throws: SetupError.self) { try timeline.append(event(#"{"v":1,"run":"other","seq":2,"type":"log"}"#)) }
        try timeline.append(event(#"{"v":1,"run":"one","seq":2,"type":"prompt","id":"login","kind":"open_url","data":{"purpose":"codex_login","url":"https://auth.openai.com/codex/device","code":"TEST-ONLY"}}"#))
        timeline.answered("wrong"); #expect(timeline.prompt != nil)
        timeline.answered("login"); #expect(timeline.prompt == nil)
        try timeline.append(event(#"{"v":1,"run":"one","seq":3,"type":"step","id":"runtime_login","status":"done"}"#))
        #expect(timeline.steps.count == 1)
        try timeline.append(event(#"{"v":1,"run":"one","seq":4,"type":"result","status":"ok","summary":"Claude is prepared for worker4 on worker4.","prepared":{"agent":"worker4","signed_in":true}}"#))
        #expect(timeline.result?.summary == "Claude is prepared for worker4 on worker4.")
        #expect(throws: SetupError.self) { try timeline.append(event(#"{"v":1,"run":"one","seq":5,"type":"log"}"#)) }
    }

    @Test func onlyThePromptsOfAPreparationAreTakenAndTheRemovedRunsPromptsAreAnInvalidStatus() throws {
        func prompt(_ kind: String, _ data: String) throws -> SetupEvent {
            try JSONDecoder().decode(SetupEvent.self, from: Data(#"{"v":1,"run":"one","seq":1,"type":"prompt","id":"p1","kind":"\#(kind)","data":\#(data)}"#.utf8))
        }
        let removed = [("confirm_host_key", #"{"host":"h","port":22,"fingerprints":[{"algorithm":"ssh-ed25519","sha256":"SHA256:test"}]}"#),
                       ("secret", #"{"label":"provider_password"}"#), ("secret", #"{"label":"tailscale_auth_key"}"#),
                       ("choice", #"{"question":"q","options":[{"value":"add","label":"Add"}]}"#)]
        for (kind, data) in removed {
            var timeline = SetupTimeline()
            #expect(throws: SetupError.self) { try timeline.append(prompt(kind, data)) }
        }
        for (kind, data) in [("terminal", #"{"purpose":"claude_login","command":"ssh -F /c -t 100.99.1.2 'x'"}"#),
                             ("open_url", #"{"purpose":"codex_login","url":"https://auth.openai.com/codex/device","code":"TEST-ONLY"}"#)] {
            var timeline = SetupTimeline()
            try timeline.append(prompt(kind, data))
            #expect(timeline.prompt?.kind == kind)
        }
    }

    @Test func loginLinksAreProviderAndPurposeBound() throws {
        func prompt(_ url: String, purpose: String = "codex_login") throws -> SetupEvent {
            let data = try JSONSerialization.data(withJSONObject: ["v": 1, "run": "one", "seq": 1, "type": "prompt", "id": "login", "kind": "open_url", "data": ["purpose": purpose, "url": url]])
            return try JSONDecoder().decode(SetupEvent.self, from: data)
        }
        #expect(try prompt("https://auth.openai.com/codex/device").loginURL != nil)
        for url in ["http://auth.openai.com/", "https://auth.openai.com.evil.example/", "file:///etc/passwd", "https://user:password@auth.openai.com/", "https://auth.openai.com:444/"] {
            #expect(try prompt(url).loginURL == nil)
        }
        #expect(try prompt("https://login.tailscale.com/", purpose: "codex_login").loginURL == nil)
        // Tailscale's link came only from the new-server run, and Claude signs in with a command (`terminal`).
        #expect(try prompt("https://login.tailscale.com/", purpose: "tailscale_login").loginURL == nil)
        #expect(try prompt("https://claude.ai/oauth/authorize", purpose: "claude_login").loginURL == nil)
    }

    @Test func aResultSurvivesTheHelperEventRoundTrip() throws {
        let data = Data(#"{"v":1,"run":"setup","seq":1,"type":"result","status":"needs_owner","summary":"This Mac did not set up vps.","prepared":{"agent":"vps","executable":null}}"#.utf8)
        let helperEvent = try JSONDecoder().decode(SetupEvent.self, from: data)
        let appEvent = try JSONDecoder().decode(SetupEvent.self, from: JSONEncoder().encode(helperEvent))
        #expect(appEvent == helperEvent)
        var timeline = SetupTimeline()
        try timeline.append(appEvent)
        #expect(timeline.result?.status == "needs_owner" && timeline.result?.summary == "This Mac did not set up vps.")
    }

    @Test func deviceCodeStaysVisibleUntilTheSignInStepFinishes() throws {
        func event(_ fields: String) throws -> SetupEvent {
            try JSONDecoder().decode(SetupEvent.self, from: Data(fields.utf8))
        }
        var timeline = SetupTimeline()
        try timeline.append(event(#"{"v":1,"run":"one","seq":1,"type":"step","id":"runtime_login","status":"running"}"#))
        try timeline.append(event(#"{"v":1,"run":"one","seq":2,"type":"prompt","id":"login","kind":"open_url","data":{"purpose":"codex_login","url":"https://auth.openai.com/codex/device","code":"TEST-ONLY"}}"#))
        timeline.answered("wrong")
        #expect(timeline.prompt != nil)
        #expect(timeline.signIn == nil)
        timeline.answered("login")
        #expect(timeline.prompt == nil)
        #expect(timeline.signIn?.data?.code == "TEST-ONLY")
        try timeline.append(event(#"{"v":1,"run":"one","seq":3,"type":"log","text":"Waiting for sign-in"}"#))
        #expect(timeline.signIn?.loginURL?.host == "auth.openai.com")
        var failed = timeline
        try failed.append(event(#"{"v":1,"run":"one","seq":4,"type":"result","status":"failed"}"#))
        #expect(failed.signIn == nil)
        try timeline.append(event(#"{"v":1,"run":"one","seq":4,"type":"step","id":"runtime_login","status":"done"}"#))
        #expect(timeline.signIn == nil)
    }

    @Test func eachPromptTakesOnlyItsOwnAnswerAsTheSetupServiceChecksIt() throws {
        func prompt(_ kind: String, _ data: [String: Any]) throws -> SetupEvent {
            try JSONDecoder().decode(SetupEvent.self, from: JSONSerialization.data(withJSONObject: [
                "v": 1, "run": "one", "seq": 1, "type": "prompt", "id": "p1", "kind": kind, "data": data]))
        }
        // The app's answer after the same JSON round trip that the setup service decodes.
        func wire(_ value: Any) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
                                             options: .fragmentsAllowed)
        }
        let copied = try wire("copied"), opened = try wire("opened"), sent = try wire("sent"), yes = try wire(true)
        let add = try wire("add")
        let command = #"ssh -F /c -t 100.99.1.2 'runuser -u fleet -- bash -lc x'"#
        let terminal = try prompt("terminal", ["purpose": "claude_login", "command": command])
        let wrongPurpose = try prompt("terminal", ["purpose": "codex_login", "command": command])
        let wrongCommand = try prompt("terminal", ["purpose": "claude_login", "command": "rm -rf ~"])
        #expect(terminal.accepts(copied))
        #expect(!terminal.accepts(opened))
        #expect(!wrongPurpose.accepts(copied) && !wrongCommand.accepts(copied))
        let link = try prompt("open_url", ["purpose": "codex_login", "url": "https://auth.openai.com/codex/device"])
        #expect(link.accepts(opened) && !link.accepts(copied))
        // What only the removed runs asked takes no answer: a secret, a host key to trust, a choice.
        let secret = try prompt("secret", ["label": "provider_password"])
        let host = try prompt("confirm_host_key", ["host": "h"])
        let choice = try prompt("choice", ["question": "q", "options": [["value": "add", "label": "Add"]]])
        let unknown = try prompt("unknown", ["purpose": "x"])
        #expect(!secret.accepts(sent) && !host.accepts(yes) && !choice.accepts(add) && !unknown.accepts(copied))
    }

    @Test func aClaudeTerminalCommandIsShownAndKeptOnlyWhileItsStepWaits() throws {
        func prompt(_ command: String, purpose: String = "claude_login") throws -> SetupEvent {
            try JSONDecoder().decode(SetupEvent.self, from: JSONSerialization.data(withJSONObject: [
                "v": 1, "run": "one", "seq": 2, "type": "prompt", "id": "login", "kind": "terminal",
                "data": ["purpose": purpose, "command": command]]))
        }
        let command = #"ssh -F /Users/o/.fleet/ssh/config -t 100.99.1.2 'runuser -u fleet -- bash -lc '"'"'cd "$HOME/fleet-pilot"'"'"''"#
        #expect(try prompt(command).terminalCommand == command && prompt(command).loginURL == nil)
        #expect(try prompt(command, purpose: "codex_login").terminalCommand == nil)
        #expect(try prompt("ssh -F c -t 100.99.1.2 'claude'\nrm -rf ~").terminalCommand == nil)    // one line only
        #expect(try prompt("open -a Terminal").terminalCommand == nil)
        var timeline = SetupTimeline()
        try timeline.append(JSONDecoder().decode(SetupEvent.self, from: Data(#"{"v":1,"run":"one","seq":1,"type":"step","id":"runtime_login","status":"running"}"#.utf8)))
        try timeline.append(prompt(command))
        timeline.answered("login")                                        // Copy answers; only the step ends the wait
        #expect(timeline.prompt == nil && timeline.signIn?.terminalCommand == command)
        try timeline.append(JSONDecoder().decode(SetupEvent.self, from: Data(#"{"v":1,"run":"one","seq":3,"type":"step","id":"runtime_login","status":"done"}"#.utf8)))
        #expect(timeline.signIn == nil)
    }
}
