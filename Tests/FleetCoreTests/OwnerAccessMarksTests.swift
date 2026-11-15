import Foundation
import Testing
@testable import FleetCore

/// What the owner's Mac keeps of the owner's access line on each fleet server. A new server with the name of a removed
/// server has another private address, so it is not taken for the removed one and gets its line.
struct OwnerAccessMarksTests {
    private let hub = URL(string: "http://hub.example:8765/")!
    private let key = "SHA256:examplekey"

    @Test func aNewServerWithTheNameOfARemovedServerIsNotSkipped() {
        var marks = OwnerAccessMarks()
        marks.keep(key, for: "worker-1", address: "100.64.0.1", hub: hub)
        #expect(marks.step("worker-1", address: "100.64.0.1", hub: hub, fingerprint: key) == .inPlace)
        // The same name at a new address is a new server.
        #expect(marks.step("worker-1", address: "100.64.0.9", hub: hub, fingerprint: key) == .run)

        // Its line in place: its mark replaces the mark of the removed server.
        marks.keep(key, for: "worker-1", address: "100.64.0.9", hub: hub)
        #expect(marks.step("worker-1", address: "100.64.0.9", hub: hub, fingerprint: key) == .inPlace)
        #expect(marks.step("worker-1", address: "100.64.0.1", hub: hub, fingerprint: key) == .run)
        #expect(marks.all == ["http://hub.example:8765/ worker-1 100.64.0.9": key])
    }

    @Test func anotherKeyOrAnotherHubHasNoMark() {
        var marks = OwnerAccessMarks()
        marks.keep(key, for: "worker-1", address: "100.64.0.1", hub: hub)
        #expect(marks.step("worker-1", address: "100.64.0.1", hub: hub, fingerprint: "SHA256:anotherkey") == .run)
        let other = URL(string: "http://other.example:8765/")!
        #expect(marks.step("worker-1", address: "100.64.0.1", hub: other, fingerprint: key) == .run)

        // A mark of another hub, or of a server whose name starts with this name, stays.
        marks.keep(key, for: "worker-1", address: "100.64.0.1", hub: other)
        marks.keep(key, for: "worker-10", address: "100.64.0.10", hub: hub)
        marks.keep(key, for: "worker-1", address: "100.64.0.2", hub: hub)
        #expect(marks.all.count == 3)
        #expect(marks.step("worker-10", address: "100.64.0.10", hub: hub, fingerprint: key) == .inPlace)
        #expect(marks.step("worker-1", address: "100.64.0.1", hub: other, fingerprint: key) == .inPlace)
    }

    /// A mark of the app before 14 November 2026: the hub's address and the server's name, as the app wrote it.
    @Test func anOldMarkGivesOneTryAndThenAMarkWithTheAddress() {
        var marks = OwnerAccessMarks(["http://hub.example:8765/ worker-1": key, "http://hub.example:8765/ worker-10": key])
        #expect(marks.step("worker-1", address: "100.64.0.1", hub: hub, fingerprint: key) == .once)
        #expect(marks.step("worker-1", address: "100.64.0.1", hub: hub, fingerprint: "SHA256:anotherkey") == .run)
        #expect(marks.step("worker-2", address: "100.64.0.2", hub: hub, fingerprint: key) == .run)

        marks.keep(key, for: "worker-1", address: "100.64.0.1", hub: hub)
        #expect(marks.step("worker-1", address: "100.64.0.1", hub: hub, fingerprint: key) == .inPlace)
        #expect(marks.all["http://hub.example:8765/ worker-1"] == nil)
        #expect(marks.step("worker-10", address: "100.64.0.10", hub: hub, fingerprint: key) == .once)

        // A server with no address yet: its mark is not the old mark of its name.
        var none = OwnerAccessMarks(["http://hub.example:8765/ worker-3": key])
        #expect(none.step("worker-3", address: nil, hub: hub, fingerprint: key) == .once)
        none.keep(key, for: "worker-3", address: nil, hub: hub)
        #expect(none.all == ["http://hub.example:8765/ worker-3 ": key])
        #expect(none.step("worker-3", address: nil, hub: hub, fingerprint: key) == .inPlace)
    }

    @Test func aServerWithAnOldMarkIsTriedOnceInALaunchAndAnUnmarkedServerSixTimes() {
        let once = OwnerAccessMarks.Step.once.failed(after: nil, at: 1000, reason: "no connection")
        #expect(once.givenUp)
        #expect(!once.isDue(at: 1000 + VaultTries.wait))

        var tries: VaultTries?
        for count in 1...VaultTries.most {
            #expect(tries.map { $0.isDue(at: Double(count) * VaultTries.wait) } ?? true)
            tries = OwnerAccessMarks.Step.run.failed(after: tries, at: Double(count) * VaultTries.wait, reason: "no connection")
            #expect(tries?.failures == count)
        }
        #expect(tries?.givenUp == true)
    }
}
