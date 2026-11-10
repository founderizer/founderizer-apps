#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import FleetCore

/// The sitting's proof that this Mac's own Chrome answers: a page that only this Mac can reach.
struct LocalProofPageTests {
    private func read(_ address: URL, method: String = "GET") async throws -> (Int, String) {
        var request = URLRequest(url: address)
        request.httpMethod = method
        request.timeoutInterval = 5
        let (data, answer) = try await URLSession.shared.data(for: request)
        return ((answer as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    @Test func thePageItselfIsNoProofUntilItsScriptAnswers() async throws {
        let page = LocalProofPage()
        let address = try page.start()
        defer { page.stop() }
        let (status, body) = try await read(address)
        #expect(status == 200)
        #expect(body.contains("fetch(location.pathname,{method:'POST'})"))
        #expect(!page.seen)
        #expect(try await read(address, method: "POST").0 == 200)
        #expect(page.seen)
    }

    @Test func aWrongAddressProvesNothing() async throws {
        let page = LocalProofPage(token: "right")
        let address = try page.start()
        defer { page.stop() }
        let wrong = address.deletingLastPathComponent().appendingPathComponent("wrong")
        #expect(try await read(wrong, method: "POST").0 == 404)
        #expect(!page.seen)
    }

    @Test func itAnswersOnThisMacAlone() async throws {
        let page = LocalProofPage()
        let address = try page.start()
        defer { page.stop() }
        #expect(address.host == "127.0.0.1")
        guard let own = ownAddress(), var parts = URLComponents(url: address, resolvingAgainstBaseURL: false) else { return }
        parts.host = own
        let outside = try #require(parts.url)
        await #expect(throws: (any Error).self) { _ = try await read(outside, method: "POST") }
        #expect(!page.seen)
    }

    /// This Mac's address on its own network, nil on a machine with none.
    private func ownAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let raw = item.pointee.ifa_addr, raw.pointee.sa_family == sa_family_t(AF_INET),
                  item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(raw, socklen_t(raw.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }
}
#endif
