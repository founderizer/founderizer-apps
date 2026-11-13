import Foundation
import Testing
@testable import FleetCore

/// The owner is at the Mac app (quiet phone): the pure rule, and the header on the state read.
struct OwnerPresenceTests {
    @Test func presentOnlyWithTheAppInFrontTheScreenOpenAndRecentInput() {
        #expect(OwnerPresence.present(appActive: true, screenLocked: false, secondsSinceInput: 0))
        #expect(OwnerPresence.present(appActive: true, screenLocked: false, secondsSinceInput: 119.9))
        #expect(!OwnerPresence.present(appActive: true, screenLocked: false, secondsSinceInput: 120))
        #expect(!OwnerPresence.present(appActive: false, screenLocked: false, secondsSinceInput: 1))
        #expect(!OwnerPresence.present(appActive: true, screenLocked: true, secondsSinceInput: 1))
        #expect(!OwnerPresence.present(appActive: true, screenLocked: false, secondsSinceInput: nil))
        #expect(!OwnerPresence.present(appActive: true, screenLocked: false, secondsSinceInput: .infinity))
        #expect(!OwnerPresence.present(appActive: true, screenLocked: false, secondsSinceInput: -1))
        #expect(OwnerPresence.idle == AppUpdatePolicy.away)
    }

    private func headers(present: Bool) async throws -> String {
        let hub = try OneAnswer(status: "200 OK") { _ in "{}" }
        _ = try? await HubClient(reads: HubReads()).stateReading(at: URL(string: "http://127.0.0.1:\(hub.port)/")!,
                                                                 present: present)
        let message = String(decoding: hub.received, as: UTF8.self)
        return String(message[..<(message.range(of: "\r\n\r\n")?.lowerBound ?? message.endIndex)]).lowercased()
    }

    @Test func theStateReadCarriesTheHeaderOnlyWhilePresent() async throws {
        #expect(try await headers(present: true).contains("\r\nx-fleet-present: 1"))
        #expect(!(try await headers(present: false).contains("x-fleet-present")))
    }

    @Test func aPresentReadIsNotSharedWithAPlainOne() throws {
        var plain = URLRequest(url: URL(string: "http://127.0.0.1:1/ui/state")!)
        let configuration = URLSessionConfiguration.ephemeral
        let key = HubReads.key(plain, in: configuration)
        plain.setValue("1", forHTTPHeaderField: OwnerPresence.header)
        #expect(HubReads.key(plain, in: configuration) != key)
    }
}
