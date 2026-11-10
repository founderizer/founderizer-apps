import Darwin
import FleetCore
import Foundation

final class ScreenSharingTunnels: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fleet.screen-sharing")
    private struct Connection { let process: Process; let port: Int; let folder: URL }
    private var connections: [ScreenSharingConnection: Connection] = [:]

    // XPC reply blocks are delivered on this private queue only.
    private struct Reply: @unchecked Sendable { let call: (Int, String) -> Void }
    private struct Closed: @unchecked Sendable { let call: () -> Void }

    func open(_ data: Data, reply: @escaping (Int, String) -> Void) {
        let reply = Reply(call: reply)
        queue.async {
            guard let request = self.request(data) else { reply.call(0, "The machine connection is invalid."); return }
            if let existing = self.connections[request] {
                if existing.process.isRunning, self.desktopReady(port: existing.port) {
                    reply.call(existing.port, ""); return
                }
                self.stop(existing); self.connections.removeValue(forKey: request)
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fleet-vnc-" + String(UUID().uuidString.prefix(8)))
            let control = folder.appendingPathComponent("c").path
            guard control.utf8.count < 104, let port = self.availablePort(),
                  let arguments = request.masterArguments(controlPath: control),
                  let forward = request.forwardArguments(controlPath: control, localPort: port) else {
                reply.call(0, "A local Screen Sharing connection could not be opened."); return
            }
            let child = self.ssh(arguments)
            let connection = Connection(process: child, port: port, folder: folder)
            guard mkdir(folder.path, 0o700) == 0 else {
                reply.call(0, "A private Screen Sharing connection could not be created."); return
            }
            var keep = false
            defer { if !keep { self.stop(connection) } }
            do { try child.run() } catch { reply.call(0, "SSH could not start."); return }
            let deadline = Date().addingTimeInterval(15)
            while child.isRunning && Date() < deadline {
                if FileManager.default.fileExists(atPath: control) { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            let forwarding = self.ssh(forward)
            if child.isRunning, FileManager.default.fileExists(atPath: control),
               self.runControl(forwarding), self.desktopReady(port: port), child.isRunning {
                self.connections[request] = connection; keep = true
                reply.call(port, ""); return
            }
            reply.call(0, "Screen Sharing did not answer through SSH. Open Terminal to check SSH sign-in, host trust and Screen Sharing on the Mac.")
        }
    }

    func close(_ data: Data, reply: @escaping () -> Void) {
        let reply = Closed(call: reply)
        queue.async {
            if let request = self.request(data), let connection = self.connections.removeValue(forKey: request) {
                self.stop(connection)
            }
            reply.call()
        }
    }

    func closeAll() {
        queue.async {
            for connection in self.connections.values { self.stop(connection) }
            self.connections.removeAll()
        }
    }

    private func request(_ data: Data) -> ScreenSharingConnection? {
        guard data.count < 2048, let request = try? JSONDecoder().decode(ScreenSharingConnection.self, from: data),
              request.isValid else { return nil }
        return request
    }

    private func ssh(_ arguments: [String]) -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        return child
    }

    private func runControl(_ child: Process) -> Bool {
        do { try child.run() } catch { return false }
        let deadline = Date().addingTimeInterval(3)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if child.isRunning { stop(child); return false }
        return child.terminationStatus == 0
    }

    private func stop(_ connection: Connection) {
        stop(connection.process)
        try? FileManager.default.removeItem(at: connection.folder)
    }

    private func stop(_ child: Process) {
        guard child.isRunning else { return }
        child.terminate()
        let deadline = Date().addingTimeInterval(2)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
    }

    private func address(port: UInt16) -> sockaddr_in {
        var value = sockaddr_in()
        value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        value.sin_family = sa_family_t(AF_INET)
        value.sin_port = port.bigEndian
        value.sin_addr.s_addr = inet_addr("127.0.0.1")
        return value
    }

    private func availablePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var value = address(port: 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                guard bind(fd, pointer, size) == 0, getsockname(fd, pointer, &size) == 0 else { return false }
                return true
            }
        }
        return result ? Int(UInt16(bigEndian: value.sin_port)) : nil
    }

    private func desktopReady(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var value = address(port: UInt16(port))
        let connected = withUnsafePointer(to: &value) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return false }
        var banner = [UInt8](repeating: 0, count: 12)
        let count = recv(fd, &banner, banner.count, MSG_WAITALL)
        // Read only the public protocol greeting. Screen Sharing owns authentication.
        return count == 12 && banner.starts(with: Array("RFB ".utf8)) && banner.last == 10
    }
}
