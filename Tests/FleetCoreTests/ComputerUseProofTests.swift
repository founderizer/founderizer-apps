#if os(macOS)
import Foundation
import Testing
@testable import FleetCore

/// The sitting's proof that Computer Use sees the screen: a stand-in for `codex app-server` gives each answer.
struct ComputerUseProofTests {
    /// A stand-in that answers by the id of each request. The last request is what it was asked, for the test to read.
    private func server(_ folder: URL, status: String = "ready", answer: String, silent: Bool = false) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("codex")
        let script = """
        #!/usr/bin/python3
        import json, sys, time
        def say(o): print(json.dumps(o), flush=True)
        log = open("\(folder.path)/asked", "w")
        if \(silent ? "True" : "False"): time.sleep(30)
        for line in sys.stdin:
            m = json.loads(line)
            log.write(line); log.flush()
            if m.get("id") == 1: say({"id": 1, "result": {}})
            elif m.get("id") == 2:
                say({"method": "mcpServer/startupStatus/updated", "params": {"name": "node_repl", "status": "failed"}})
                say({"id": 2, "result": {"thread": {"id": "t-1"}}})
                say({"method": "mcpServer/startupStatus/updated", "params": {"name": "cua_repl", "status": "\(status)"}})
            elif m.get("id") == 3:
                say({"id": 77, "method": "mcpServer/elicitation/request", "params": {"serverName": "cua_repl"}})
            elif m.get("id") == 77:
                say({"id": 3, "result": \(answer)})
                time.sleep(30)
        """
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }

    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @Test func anImageIsTheProof() async throws {
        let place = folder()
        defer { try? FileManager.default.removeItem(at: place) }
        let codex = try server(place, answer: "{'isError': False, 'content': [{'type': 'text', 'text': 'x'}, {'type': 'image', 'data': 'y'}]}")
        #expect(await ComputerUseProof.screenshot(codex: codex, limit: 20))
        let asked = try String(contentsOf: place.appendingPathComponent("asked"), encoding: .utf8)
        #expect(asked.contains("\"threadId\":\"t-1\""))
        #expect(asked.contains("getScreenshot"))
        #expect(asked.contains("\"accept\""))           // the runtime's question for the tool was answered
    }

    @Test func wordsWithNoImageProveNothing() async throws {
        let place = folder()
        defer { try? FileManager.default.removeItem(at: place) }
        let codex = try server(place, answer: "{'isError': False, 'content': [{'type': 'text', 'text': 'x'}]}")
        #expect(await !ComputerUseProof.screenshot(codex: codex, limit: 20))
    }

    @Test func aCallThatTimedOutProvesNothing() async throws {
        let place = folder()
        defer { try? FileManager.default.removeItem(at: place) }
        let codex = try server(place, answer: "{'isError': True, 'content': [{'type': 'image', 'data': 'y'}]}")
        #expect(await !ComputerUseProof.screenshot(codex: codex, limit: 20))
    }

    @Test func aHelperThatDidNotStartEndsTheCall() async throws {
        let place = folder()
        defer { try? FileManager.default.removeItem(at: place) }
        let codex = try server(place, status: "failed", answer: "{}")
        #expect(await !ComputerUseProof.screenshot(codex: codex, limit: 20))
        #expect(try !String(contentsOf: place.appendingPathComponent("asked"), encoding: .utf8).contains("tool/call"))
    }

    @Test func aRuntimeThatNeverAnswersEndsAtTheLimit() async throws {
        let place = folder()
        defer { try? FileManager.default.removeItem(at: place) }
        let codex = try server(place, answer: "{}", silent: true)
        let start = Date()
        #expect(await !ComputerUseProof.screenshot(codex: codex, limit: 1))
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func aCancelledCallEndsItsRuntime() async throws {
        let place = folder()
        defer { try? FileManager.default.removeItem(at: place) }
        let codex = try server(place, answer: "{}", silent: true)
        let start = Date()
        let call = Task { await ComputerUseProof.screenshot(codex: codex, limit: 25) }
        try await Task.sleep(for: .milliseconds(300))
        call.cancel()
        #expect(await !call.value)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func aMissingRuntimeProvesNothing() async {
        #expect(await !ComputerUseProof.screenshot(codex: "/nowhere/codex", limit: 1))
    }

    /// The page's spinner goes when OpenAI's window is on the screen: a window of the helper's app, and not its cursor.
    @Test func theHelpersWindowIsReadFromTheWindowList() {
        func window(_ owner: String, _ width: Double, _ height: Double) -> [String: Any] {
            ["kCGWindowOwnerName": owner, "kCGWindowBounds": ["X": NSNumber(value: 0), "Y": NSNumber(value: 0),
                                                            "Width": NSNumber(value: width), "Height": NSNumber(value: height)]]
        }
        #expect(ComputerUseProof.windowShows(in: [window("ChatGPT", 1024, 680), window("ChatGPT Computer Use", 600, 540)]))
        #expect(ComputerUseProof.windowShows(in: [window("Codex Computer Use", 480, 72)]))      // its guide under Settings
        #expect(!ComputerUseProof.windowShows(in: [window("ChatGPT", 1024, 680), window("System Settings", 700, 600)]))
        #expect(!ComputerUseProof.windowShows(in: [window("ChatGPT Computer Use", 32, 32)]))    // its cursor
        #expect(!ComputerUseProof.windowShows(in: [["kCGWindowOwnerName": "ChatGPT Computer Use"]]))
        #expect(!ComputerUseProof.windowShows(in: []))
    }
}
#endif
