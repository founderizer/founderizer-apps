#if os(macOS)
import CoreGraphics
import Darwin
import Foundation

/// One real screenshot through Computer Use, with no model and no tokens (the owner's test of 1 November 2026).
///
/// macOS hides both permissions of Computer Use from other apps, and OpenAI's helper lists itself on Screen Recording
/// only through its own window, "Enable ChatGPT Computer Use", which opens when something needs the screen. This call
/// needs it. So it opens that window on a Mac that lacks a permission, and on one that has both it is the proof: an image
/// comes back. It goes through the ChatGPT app's own `codex app-server`, because the helper answers no other sender.
public enum ComputerUseProof {
    private static let code = "const app = await cua.getApp(\"com.apple.finder\"); await app.getScreenshot();"

    /// True when an image came back. The runtime ends the call by itself after 30 seconds, and `limit` ends the rest.
    public static func screenshot(codex: String, limit: Double = 45) async -> Bool {
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: codex)
        child.arguments = ["app-server"]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)     // a runtime that ended stops no installer
        guard (try? child.run()) != nil else { return false }
        let clock = Task {
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            child.terminate()
            try? await Task.sleep(for: .seconds(5))
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        defer {
            clock.cancel()
            if child.isRunning { child.terminate() }
        }
        return await withTaskCancellationHandler {
            await answer(input.fileHandleForWriting, output.fileHandleForReading)
        } onCancel: {
            child.terminate()       // the read ends at the end of the runtime's output, and at nothing else
        }
    }

    private static func answer(_ input: FileHandle, _ output: FileHandle) async -> Bool {
        func send(_ message: [String: Any]) {
            guard let line = try? JSONSerialization.data(withJSONObject: message) else { return }
            try? input.write(contentsOf: line + Data("\n".utf8))
        }
        var thread: String?, ready = false, asked = false
        func ask() {
            guard let thread, ready, !asked else { return }
            asked = true
            send(["id": 3, "method": "mcpServer/tool/call",
                  "params": ["threadId": thread, "server": "cua_repl", "tool": "js",
                             "arguments": ["code": code, "title": "Screenshot"]] as [String: Any]])
        }
        send(["id": 1, "method": "initialize",
              "params": ["clientInfo": ["name": "founderizer", "title": "Founderizer", "version": "1"],
                         "capabilities": ["experimentalApi": true]] as [String: Any]])
        do {
            for try await line in output.bytes.lines {
                guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                let params = message["params"] as? [String: Any]
                if let id = message["id"], let method = message["method"] as? String {
                    // The runtime's own question for each tool call, as a screen task answers it: never a person's consent.
                    send(method == "mcpServer/elicitation/request" && params?["serverName"] as? String == "cua_repl"
                         ? ["id": id, "result": ["action": "accept", "content": [:], "_meta": ["persist": "session"]] as [String: Any]]
                         : ["id": id, "error": ["code": -32601, "message": "not handled"] as [String: Any]])
                } else if message["method"] as? String == "mcpServer/startupStatus/updated" {
                    guard params?["name"] as? String == "cua_repl" else { continue }
                    if params?["status"] as? String == "failed" { return false }
                    ready = ready || params?["status"] as? String == "ready"
                    ask()
                } else if message["id"] as? Int == 1 {
                    send(["method": "initialized"])
                    send(["id": 2, "method": "thread/start",
                          "params": ["cwd": FileManager.default.homeDirectoryForCurrentUser.path,
                                     "approvalPolicy": "on-request", "sandbox": "read-only"]])
                } else if message["id"] as? Int == 2 {
                    thread = ((message["result"] as? [String: Any])?["thread"] as? [String: Any])?["id"] as? String
                    guard thread != nil else { return false }
                    ask()
                } else if message["id"] as? Int == 3 {
                    return shown(message["result"] as? [String: Any])
                }
            }
        } catch {}
        return false
    }

    /// OpenAI's window "Enable ChatGPT Computer Use", or its guide at the bottom of System Settings, stands on this
    /// Mac's screen. macOS names the app of each window to every app, with no Screen Recording permission.
    public static func windowShows() -> Bool {
        windowShows(in: CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                        as? [[String: Any]] ?? [])
    }

    /// The same, read from one window list. The helper's app is "ChatGPT Computer Use"; its cursor and overlays are small.
    static func windowShows(in windows: [[String: Any]]) -> Bool {
        windows.contains { window in
            guard (window["kCGWindowOwnerName"] as? String)?.contains("Computer Use") == true,
                  let bounds = window["kCGWindowBounds"] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else { return false }
            return width >= 200 && height >= 60
        }
    }

    private static func shown(_ result: [String: Any]?) -> Bool {
        guard let result, result["isError"] as? Bool != true, let content = result["content"] as? [[String: Any]] else { return false }
        return content.contains { $0["type"] as? String == "image" }
    }
}
#endif
