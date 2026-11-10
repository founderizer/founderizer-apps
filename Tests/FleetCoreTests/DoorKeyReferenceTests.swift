import Foundation
import Testing
@testable import FleetCore

/// One catalog entry for one App key on its way to the door. On 6 November 2026 each failed round of the move of the
/// hub's App key made a new reference, and five hours later the hub's catalog held 49 entries named
/// GITHUB_APP_ACME_KEY.
struct DoorKeyReferenceTests {
    static let hub = URL(string: "http://100.64.0.1:8765")!

    static func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "door-key-reference-test-\(UUID().uuidString)"))
    }

    @Test func aRoundThatFailedTriesAgainUnderTheSameReference() throws {
        let defaults = try Self.defaults()
        let first = DoorKeyReference.take(hub: Self.hub, database: "db1", app: "123", in: defaults)
        #expect(LoginSecret.isReference(first))
        for _ in 1...48 {
            #expect(DoorKeyReference.take(hub: Self.hub, database: "db1", app: "123", in: defaults) == first)
        }
        // another App, another generation of the hub's database or another hub has its own
        let others = [DoorKeyReference.take(hub: Self.hub, database: "db1", app: "456", in: defaults),
                      DoorKeyReference.take(hub: Self.hub, database: "db2", app: "123", in: defaults),
                      DoorKeyReference.take(hub: URL(string: "http://100.64.0.2:8765")!, database: "db1", app: "123",
                                            in: defaults)]
        #expect(Set(others + [first]).count == 4)
    }

    @Test func theReferenceGoesOnceTheDoorsFileNamesTheApp() throws {
        let defaults = try Self.defaults()
        let first = DoorKeyReference.take(hub: Self.hub, database: "db1", app: "123", in: defaults)
        let other = DoorKeyReference.take(hub: Self.hub, database: "db1", app: "456", in: defaults)
        DoorKeyReference.done(hub: Self.hub, database: "db1", app: "123", in: defaults)
        let next = DoorKeyReference.take(hub: Self.hub, database: "db1", app: "123", in: defaults)
        #expect(next != first && LoginSecret.isReference(next))
        #expect(DoorKeyReference.take(hub: Self.hub, database: "db1", app: "456", in: defaults) == other)
    }

    @Test func aKeptValueThatIsNoReferenceIsReplaced() throws {
        let defaults = try Self.defaults()
        defaults.set("not a reference", forKey: DoorKeyReference.key(hub: Self.hub, database: "db1", app: "123"))
        let made = DoorKeyReference.take(hub: Self.hub, database: "db1", app: "123", in: defaults)
        #expect(LoginSecret.isReference(made))
        #expect(DoorKeyReference.take(hub: Self.hub, database: "db1", app: "123", in: defaults) == made)
    }
}
