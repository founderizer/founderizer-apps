import Foundation
import FleetSetupIPC

@main struct SetupProbe {
    static func main() async throws {
        let connection = NSXPCConnection(serviceName: SetupServiceID.name)
        connection.remoteObjectInterface = NSXPCInterface(with: FleetSetupServiceProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        func proxy() -> FleetSetupServiceProtocol {
            connection.remoteObjectProxyWithErrorHandler { error in
                FileHandle.standardError.write(Data("XPC connection failed: \(error)\n".utf8)); exit(2)
            } as! FleetSetupServiceProtocol
        }
        let ready = await withCheckedContinuation { continuation in proxy().availability { ok, _ in continuation.resume(returning: ok) } }
        guard ready else { fatalError("Setup helper unavailable") }
        // A key selected on an earlier attempt must not block a different access method.
        let config = Data(#"{"host":"fixture.invalid","port":22,"login":"root","name":"fixture","runtime":"codex","resume":false,"auth":"password","identityFile":"/fleet-fixture-missing-key","hub":"http://localhost:8765"}"#.utf8)
        let started = await withCheckedContinuation { continuation in proxy().start(configuration: config) { ok, _ in continuation.resume(returning: ok) } }
        guard started else { fatalError("Setup did not start") }
        func answer(_ prompt: String, _ value: String, secret: Data? = nil) async -> Bool {
            await withCheckedContinuation { continuation in
                proxy().answer(prompt: prompt, value: Data(value.utf8), secret: secret) { continuation.resume(returning: $0) }
            }
        }
        var cursor = 0
        var done = false
        for _ in 0..<300 {
            let reply: (Data, Bool, String) = await withCheckedContinuation { continuation in proxy().readEvents(after: cursor) { continuation.resume(returning: ($0, $1, $2)) } }
            if !reply.2.isEmpty { print("Events before failure: \(String(decoding: reply.0, as: UTF8.self))"); fflush(stdout); fatalError(reply.2) }
            let text = String(decoding: reply.0, as: UTF8.self)
            guard !text.contains("synthetic-fd3-canary") else { fatalError("Secret appeared in event data") }
            let events = try JSONSerialization.jsonObject(with: reply.0) as! [[String: Any]]
            for event in events {
                cursor = event["seq"] as! Int
                if event["type"] as? String == "prompt" {
                    switch event["id"] as? String {
                    case "password":
                        guard await answer("password", #""sent""#, secret: Data("synthetic-fd3-canary".utf8)) else { fatalError("Secret response rejected") }
                    case "bad-terminal":
                        guard !(await answer("bad-terminal", #""copied""#)) else { fatalError("A wrong-purpose terminal answer was accepted") }
                    case "terminal":
                        guard !(await answer("terminal", #""opened""#)) else { fatalError("A wrong terminal answer was accepted") }
                        guard !(await answer("terminal", #""copied""#, secret: Data("synthetic-fd3-canary".utf8))) else {
                            fatalError("A terminal answer with a secret was accepted")
                        }
                        guard await answer("terminal", #""copied""#) else { fatalError("Copy command was rejected") }
                    default: fatalError("Unexpected prompt \(event)")
                    }
                }
                if event["type"] as? String == "result" {
                    done = event["status"] as? String == "ok"
                    if !done { print(event); fflush(stdout) }
                    let machine = event["machine"] as? [String: Any]
                    let security = machine?["security"] as? [String: Any]
                    guard security?["pending_security"] as? Int == 3,
                          security?["reboot_required"] as? Bool == true else {
                        fatalError("Setup helper dropped security update status")
                    }
                }
            }
            if !reply.1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard done, cursor == 8 else { fatalError("Setup did not finish") }
        // A provider's setup for an existing agent: the service refuses other access or resume, and runs the agreed command.
        func start(_ json: String) async -> Bool {
            await withCheckedContinuation { continuation in proxy().start(configuration: Data(json.utf8)) { ok, _ in continuation.resume(returning: ok) } }
        }
        let prepare = #"{"host":"","port":22,"login":"root","name":"","runtime":"claude","auth":"agent","hub":"http://localhost:8765","prepareRuntime":"worker4","generation":"g1","machine":"worker4","resume":"#
        guard !(await start(prepare + "true}")) else { fatalError("A preparation run with resume started") }
        guard !(await start(prepare.replacingOccurrences(of: #""auth":"agent""#, with: #""auth":"password""#) + "false}")) else {
            fatalError("A preparation run with password access started")
        }
        guard await start(prepare + "false}") else { fatalError("The preparation run did not start") }
        var prepared = false
        cursor = 0
        for _ in 0..<100 {
            let reply: (Data, Bool, String) = await withCheckedContinuation { continuation in proxy().readEvents(after: cursor) { continuation.resume(returning: ($0, $1, $2)) } }
            if !reply.2.isEmpty { fatalError(reply.2) }
            for event in try JSONSerialization.jsonObject(with: reply.0) as! [[String: Any]] {
                cursor = event["seq"] as! Int
                if event["type"] as? String == "result" {
                    prepared = event["status"] as? String == "ok"
                    if !prepared { print(event); fflush(stdout) }
                }
            }
            if !reply.1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard prepared, cursor == 3 else { fatalError("The preparation run did not finish") }
        // Stop: the executor starts with the default action for SIGTERM and an open mask, so Stop ends it at once, by
        // SIGTERM and long before the 5-second fallback. An executor that ignores SIGTERM itself still ends, by SIGKILL.
        func stopped(host: String) async throws -> (seconds: Double, failure: String) {
            let waiting = String(decoding: config, as: UTF8.self).replacingOccurrences(of: "fixture.invalid", with: host)
            guard await start(waiting) else { fatalError("The waiting run did not start") }
            var detail = ""
            for _ in 0..<100 where detail.isEmpty {
                let reply: (Data, Bool, String) = await withCheckedContinuation { continuation in proxy().readEvents(after: 0) { continuation.resume(returning: ($0, $1, $2)) } }
                detail = (try JSONSerialization.jsonObject(with: reply.0) as! [[String: Any]]).first?["detail"] as? String ?? ""
                if detail.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
            }
            guard detail == "SIGTERM default open" else { fatalError("The executor did not get the default SIGTERM action: \(detail)") }
            let begin = Date()
            await withCheckedContinuation { continuation in proxy().cancel { continuation.resume() } }
            for _ in 0..<160 {
                let reply: (Data, Bool, String) = await withCheckedContinuation { continuation in proxy().readEvents(after: 0) { continuation.resume(returning: ($0, $1, $2)) } }
                if !reply.1 { return (Date().timeIntervalSince(begin), reply.2) }
                try await Task.sleep(for: .milliseconds(50))
            }
            fatalError("The executor did not end after Stop")
        }
        let normal = try await stopped(host: "stop.invalid")
        guard normal.seconds < 2, normal.failure.contains("signal 15") else { fatalError("Stop did not end the executor by SIGTERM: \(normal)") }
        let stubborn = try await stopped(host: "ignore.invalid")
        guard stubborn.seconds >= 4, stubborn.failure.contains("signal 9") else { fatalError("The fallback did not end an executor that ignores SIGTERM: \(stubborn)") }
        print("PASS: signed sandbox app -> XPC helper -> Python; FD 3 secret; ordered events; terminal Copy accepted, wrong purpose, wrong answer and secret rejected; security update status; verified result; no secret in event stream; provider preparation: exact arguments, resume and password access refused; Stop: default SIGTERM at spawn, ended by SIGTERM in \(String(format: "%.2f", normal.seconds)) s, SIGKILL fallback after \(String(format: "%.1f", stubborn.seconds)) s for an executor that ignores SIGTERM")
    }
}
