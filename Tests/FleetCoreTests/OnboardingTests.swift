import Foundation
import Testing
@testable import FleetCore

struct OnboardingTests {
    @Test func configurationNeverBuildsShellText() throws {
        var config = ServerConfiguration()
        config.name = "test-mini"; config.host = "server.example.com"; config.login = "ubuntu"
        config.identityFile = "/Users/owner/SSH keys/provider key"; config.auth = "identity"
        try config.validate()
        #expect(config.arguments.suffix(2) == ["--identity-file", "/Users/owner/SSH keys/provider key"])
        config.host = "server;touch /tmp/no"
        #expect(throws: SetupError.self) { try config.validate() }
        config.host = "-oProxyCommand=anything"
        #expect(throws: SetupError.self) { try config.validate() }
        config.host = "server.example.com"; config.name = "../../other"
        #expect(throws: SetupError.self) { try config.validate() }
        config.name = "new-worker"; config.resume = true
        try config.validate()
        #expect(config.arguments.contains("--resume"))
        #expect(!config.arguments.contains("--host"))
        #expect(!String(decoding: try JSONEncoder().encode(config), as: UTF8.self).contains("password"))
    }

    @Test func protocolBindsRunAndSequenceAndTerminalState() throws {
        func event(_ fields: String) throws -> SetupEvent {
            try JSONDecoder().decode(SetupEvent.self, from: Data(fields.utf8))
        }
        var timeline = SetupTimeline()
        let first = try event(#"{"v":1,"run":"one","seq":1,"type":"step","id":"host_key","title":"Server identity","status":"running"}"#)
        try timeline.append(first)
        #expect(throws: SetupError.self) { try timeline.append(first) }
        #expect(throws: SetupError.self) { try timeline.append(event(#"{"v":1,"run":"other","seq":2,"type":"log"}"#)) }
        try timeline.append(event(#"{"v":1,"run":"one","seq":2,"type":"prompt","id":"key","kind":"confirm_host_key","data":{"host":"example.com","port":22,"fingerprints":[{"algorithm":"ed25519","sha256":"SHA256:test"}]}}"#))
        timeline.answered("wrong"); #expect(timeline.prompt != nil)
        timeline.answered("key"); #expect(timeline.prompt == nil)
        try timeline.append(event(#"{"v":1,"run":"one","seq":3,"type":"step","id":"host_key","status":"done"}"#))
        #expect(timeline.steps.count == 1)
        try timeline.append(event(#"{"v":1,"run":"one","seq":4,"type":"result","status":"ok","machine":{"name":"new-worker"}}"#))
        #expect(throws: SetupError.self) { try timeline.append(event(#"{"v":1,"run":"one","seq":5,"type":"log"}"#)) }
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
        #expect(try prompt("https://login.tailscale.com/", purpose: "tailscale_login").loginURL != nil)
    }

    @Test func securityStatusSurvivesTheHelperEventRoundTrip() throws {
        let data = Data(#"{"v":1,"run":"setup","seq":1,"type":"result","status":"ok","machine":{"name":"new-worker","security":{"pending_security":3,"reboot_required":true}}}"#.utf8)
        let helperEvent = try JSONDecoder().decode(SetupEvent.self, from: data)
        let appEvent = try JSONDecoder().decode(SetupEvent.self, from: JSONEncoder().encode(helperEvent))
        var timeline = SetupTimeline()
        try timeline.append(appEvent)
        #expect(timeline.result?.machine?.security?.pending_security == 3)
        #expect(timeline.result?.machine?.security?.reboot_required == true)

        let legacy = try JSONDecoder().decode(SetupEvent.self, from: Data(#"{"v":1,"run":"setup","seq":1,"type":"result","status":"ok","machine":{"name":"new-worker"}}"#.utf8))
        #expect(legacy.machine?.security == nil)
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
        let add = try wire("add"), other = try wire("other")
        let command = #"ssh -F /c -t 100.99.1.2 'runuser -u fleet -- bash -lc x'"#
        let terminal = try prompt("terminal", ["purpose": "claude_login", "command": command])
        let wrongPurpose = try prompt("terminal", ["purpose": "codex_login", "command": command])
        let wrongCommand = try prompt("terminal", ["purpose": "claude_login", "command": "rm -rf ~"])
        #expect(terminal.accepts(copied, secret: nil))
        #expect(!terminal.accepts(opened, secret: nil) && !terminal.accepts(copied, secret: Data("x".utf8)))   // never a secret
        #expect(!wrongPurpose.accepts(copied, secret: nil) && !wrongCommand.accepts(copied, secret: nil))
        let secret = try prompt("secret", ["label": "provider_password"])
        #expect(secret.accepts(sent, secret: Data("pw".utf8)) && !secret.accepts(sent, secret: nil))
        #expect(!secret.accepts(sent, secret: Data("a\nb".utf8)) && !secret.accepts(copied, secret: Data("pw".utf8)))
        let host = try prompt("confirm_host_key", ["host": "h"])
        let link = try prompt("open_url", ["purpose": "codex_login", "url": "https://auth.openai.com/codex/device"])
        let choice = try prompt("choice", ["question": "q", "options": [["value": "add", "label": "Add"]]])
        let unknown = try prompt("unknown", ["purpose": "x"])
        #expect(host.accepts(yes, secret: nil) && link.accepts(opened, secret: nil) && !link.accepts(copied, secret: nil))
        #expect(choice.accepts(add, secret: nil) && !choice.accepts(other, secret: nil) && !unknown.accepts(copied, secret: nil))
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

    @Test func aProviderSetupIsItsOwnTypedModeWithTheAgreedArguments() throws {
        var config = ServerConfiguration()
        config.hub = "http://100.96.10.20:8765"; config.prepareRuntime = "worker4"; config.runtime = "claude"
        config.generation = "g1"; config.machine = "worker4"
        try config.validate()
        let agreed = ["run", "--json", "--auth", "agent", "--hub", "http://100.96.10.20:8765/", "--repo", "git://100.96.10.20/fleet-pilot.git",
                      "--prepare-runtime", "worker4", "--runtime", "claude", "--generation", "g1", "--machine", "worker4"]
        #expect(config.arguments == agreed)                                             // no --resume, no --existing-machine
        let sent = try JSONDecoder().decode(ServerConfiguration.self, from: JSONEncoder().encode(config))   // as the service gets it
        #expect(sent.arguments == agreed)
        let changes: [(inout ServerConfiguration) -> Void] = [
            { $0.resume = true }, { $0.existingMachine = "vps" }, { $0.auth = "password" }, { $0.identityFile = "/key" },
            { $0.generation = nil }, { $0.machine = "bad host" }, { $0.prepareRuntime = "Worker4" }, { $0.runtime = "grok" }]
        for change in changes {
            var refused = config; change(&refused)
            #expect(throws: (any Error).self) { try refused.validate() }
        }
        func executor(_ capabilities: String) throws -> SetupExecutor {
            try JSONDecoder().decode(SetupExecutor.self, from: Data(#"{"v":1,"type":"version","executor":"1.3.0","capabilities":\#(capabilities)}"#.utf8))
        }
        #expect(try executor(#"["existing_machine","prepare_runtime"]"#).supportsRuntimePreparation)
        #expect(try !executor(#"["existing_machine"]"#).supportsRuntimePreparation)
    }
}
