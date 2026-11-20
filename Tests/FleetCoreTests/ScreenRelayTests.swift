import Darwin
import Foundation
import Testing
@testable import FleetCore

/// **The relay checks the line on Screen Sharing's own connection** (`ScreenRelay`; the owner's "Check the real line"
/// of 20 November 2026): x11vnc's greeting and every byte after it pass, and a program that answers the helper's check
/// as x11vnc does but the next connection, Screen Sharing's, as Apple's server does never reaches Screen Sharing, while
/// the relay keeps that fact for the next press.
struct ScreenRelayTests {
    private let agent = ScreenSharingConnection(address: "100.80.1.7", user: "root", port: 22, remotePort: 5911,
                                                agent: "alpha")

    /// A screen on loopback that greets its connections with `greetings` in turn and then echoes what it gets.
    private static func screen(_ greetings: [String]) throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, size) == 0 && listen(fd, 4) == 0 && getsockname(fd, $0, &size) == 0
            }
        }
        try #require(fd >= 0 && bound)
        Thread.detachNewThread {
            for greeting in greetings {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                write(client, greeting)
                var buffer = [UInt8](repeating: 0, count: 256)
                while true {
                    let count = recv(client, &buffer, buffer.count, 0)
                    guard count > 0 else { break }
                    _ = buffer.withUnsafeBytes { Darwin.send(client, $0.baseAddress, count, 0) }
                }
                Darwin.close(client)
            }
            Darwin.close(fd)
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func connect(_ port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var wait = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return fd
    }

    private static func write(_ fd: Int32, _ text: String) {
        _ = Array(text.utf8).withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    }

    private static func read(_ fd: Int32, _ count: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: count)
        let got = recv(fd, &buffer, count, MSG_WAITALL)
        return String(decoding: buffer.prefix(max(got, 0)), as: UTF8.self)
    }

    @Test func x11vncsGreetingAndTheBytesAfterItPass() throws {
        let relay = try #require(ScreenRelay(inner: try Self.screen(["RFB 003.008\n"]), request: agent))
        let viewer = Self.connect(relay.port)
        defer { Darwin.close(viewer) }
        #expect(Self.read(viewer, 12) == "RFB 003.008\n")
        Self.write(viewer, "ping")
        #expect(Self.read(viewer, 4) == "ping")
        relay.close()
        #expect(Self.read(viewer, 1) == "" && !relay.refused)
    }

    @Test func aProgramThatGreetsScreenSharingAnotherWayNeverReachesIt() throws {
        let port = try Self.screen(["RFB 003.008\n", "RFB 003.889\n"])
        let check = Self.connect(port)                              // the helper's own check, straight to the tunnel
        #expect(Self.read(check, 12) == "RFB 003.008\n")
        Darwin.close(check)
        let relay = try #require(ScreenRelay(inner: port, request: agent))
        defer { relay.close() }
        let viewer = Self.connect(relay.port)                       // Screen Sharing's own connection
        defer { Darwin.close(viewer) }
        #expect(Self.read(viewer, 12) == "")
        #expect(relay.refused)
    }
}
