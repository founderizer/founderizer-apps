import FleetCore
import Foundation
import Testing
@testable import FleetOwnerAPI

/// The program inside the app sends this Mac's own key for the hub (`OwnerComputerKey`), which the app or a claim
/// wrote: the hub knows the owner's Mac by its address and that key, both.
final class OwnerKeyTests {
    let home = Fixture.home()
    deinit { try? FileManager.default.removeItem(at: home) }
    static let key = "k" + String(repeating: "d", count: 42)

    /// A hub at an address of its own that is written as a number, as a fleet's hub is: the key's file of a hub that
    /// is called by a name is found by a lookup, and no test asks a resolver.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last = 0
    private static func hub() -> StandInHub {
        let number = lock.withLock { last += 1; return last }
        return StandInHub(features: Fixture.everyFeature, host: "100.67.\(number / 250 % 250).\(number % 250 + 2)")
    }

    private func keep(_ key: String, for hub: StandInHub) throws {
        try OwnerMacKey.keep(key, hub: try #require(URL(string: hub.base)), home: home)       // as the app writes it
    }

    /// A hub that holds the SHA-256 of `key`, or none: the three answers of `hub.py` `owner_allowed`.
    private func asking(_ hub: StandInHub, for key: String?) {
        hub.answer = { seen in
            let sent = seen.header("Authorization")
            func refusal(_ auth: String) -> (Int, JSONValue) {
                (403, .object(["error": .string("the hub's own words"), "auth": .string(auth)]))
            }
            guard let key else { return sent == nil ? nil : refusal("key_not_expected") }
            guard let sent else { return refusal("owner_key_required") }
            return sent == "Bearer " + key ? nil : refusal("owner_key_mismatch")
        }
    }

    @Test func theFileHasTheNameThatTheAppGivesIt() throws {
        for base in ["http://100.64.0.9:8765", "http://Hub.Example.COM:9000", "http://hub.example", "https://hub.example",
                     "http://[fd7a:115c:a1e0::1]:8765", "100.64.0.9:8765"] {
            let url = try #require(URL(string: base.contains("://") ? base : "http://" + base))
            #expect(OwnerComputerKey.name(base: base) == OwnerMacKey.name(hub: url), "\(base)")
        }
        #expect(OwnerComputerKey.name(base: "http://100.64.0.9:8765") == "100.64.0.9_8765")
    }

    @Test func aCallCarriesTheKeyThatTheAppKept() throws {
        let hub = Self.hub()
        asking(hub, for: Self.key)
        try keep(Self.key, for: hub)
        let tools = Fixture.tools(hub, home: home)
        #expect(tools.refused("fleet_overview") == nil)
        #expect(tools.refused("take_release") == nil)
        #expect(!hub.seen.isEmpty)
        #expect(hub.seen.allSatisfy { $0.header("Authorization") == "Bearer " + Self.key })
    }

    @Test func aMacWithNoKeySendsNoneAndAHubFromBeforeTheKeyTakesIt() {
        let hub = Self.hub()
        asking(hub, for: nil)
        #expect(Fixture.tools(hub, home: home).refused("fleet_overview") == nil)
        #expect(hub.seen.allSatisfy { $0.header("Authorization") == nil })
    }

    @Test func aHubFromBeforeTheKeyGetsTheCallAgainWithNoKey() throws {
        let hub = Self.hub()
        asking(hub, for: nil)
        try keep(Self.key, for: hub)
        let tools = Fixture.tools(hub, home: home)
        #expect(tools.refused("fleet_overview") == nil)
        let sent = hub.seen.map { $0.header("Authorization") }
        #expect(sent.first == "Bearer " + Self.key)
        #expect(sent.contains(nil))
        // Each request that carried the key was refused before the hub did anything, and went again without.
        #expect(sent.filter { $0 != nil }.count == sent.filter { $0 == nil }.count)
    }

    @Test func theRefusalForWantOfTheKeySaysWhereTheKeyIsAndWhoMakesIt() throws {
        let hub = Self.hub()
        asking(hub, for: Self.key)
        let none = try #require(Fixture.tools(hub, home: home).refused("fleet_overview"))
        #expect(none.contains("the hub's own words"))
        #expect(none.contains("this program has none for this hub in ~/.founderizer/owner-keys"))
        #expect(none.contains("Open Founderizer on this computer once"))
        #expect(none.contains("A program in a VM or a container on this computer is not the owner."))
        let held = "k" + String(repeating: "e", count: 42)
        try keep(held, for: hub)
        let other = try #require(Fixture.tools(hub, home: home).refused("fleet_overview"))
        #expect(other.contains("this program has another one for this hub"))
        #expect(!other.contains(held))                  // the key that this program holds is in no words of its own
        #expect(!other.contains(Self.key))
    }

    /// As the app finds it (`OwnerMacKey.found`): one hub address has one key file, named by its number. The claim's
    /// line writes it, and a program that calls the hub by its name reads it through the lookup of that name.
    @Test func oneHubAddressHasOneKeyFileNamedByItsNumber() throws {
        let lookup: (String) -> String? = { ["hub-1.tail1234.ts.net": "100.64.0.9", "other.tail1234.ts.net": "100.64.0.10"][$0] }
        let byName = "http://hub-1.tail1234.ts.net:8765", byNumber = "http://100.64.0.9:8765"
        let nameURL = try #require(URL(string: byName)), numberURL = try #require(URL(string: byNumber))
        #expect(OwnerComputerKey.read(base: byName, home: home, lookup: { _ in Issue.record("it looked a name up"); return nil }) == nil)
        try OwnerMacKey.keep(Self.key, hub: numberURL, home: home)
        #expect(OwnerComputerKey.read(base: byName, home: home, lookup: lookup) == Self.key)
        #expect(OwnerComputerKey.read(base: "http://other.tail1234.ts.net:8765", home: home, lookup: lookup) == nil)
        #expect(OwnerComputerKey.read(base: "http://hub-1.tail1234.ts.net:9000", home: home, lookup: lookup) == nil)
        #expect(OwnerComputerKey.read(base: byName, home: home, lookup: lookup) == OwnerMacKey.read(hub: nameURL, home: home, lookup: lookup))
        #expect(OwnerComputerKey.read(base: byNumber, home: home, lookup: lookup) == Self.key)
        // A file with the name as it is written is never the key, as in the app: with a number the file of the
        // number is, and a name that has no number now has no key.
        let old = "k" + String(repeating: "e", count: 42)
        let folder = home.appendingPathComponent(".founderizer/owner-keys", isDirectory: true)
        try Data((old + "\n").utf8).write(to: folder.appendingPathComponent("hub-1.tail1234.ts.net_8765"))
        #expect(OwnerComputerKey.read(base: byName, home: home, lookup: lookup) == Self.key)
        #expect(OwnerComputerKey.read(base: byName, home: home, lookup: { _ in nil }) == nil)
        #expect(OwnerMacKey.read(hub: nameURL, home: home, lookup: { _ in nil }) == nil)
        #expect(OwnerComputerKey.read(base: byName, home: home, lookup: { _ in "not an address" }) == nil)
        // A key that the app keeps for the hub by its name is the key of the number.
        try OwnerMacKey.keep(old, hub: nameURL, home: home, lookup: lookup)
        #expect(OwnerComputerKey.read(base: byNumber, home: home, lookup: lookup) == old)
        // A key that waits for its hub's answer is the app's to try: this program reads a key only.
        try OwnerMacKey.keepWaiting("k" + String(repeating: "f", count: 42), hub: URL(string: "http://100.64.0.20:8765")!, home: home)
        #expect(OwnerComputerKey.read(base: "http://100.64.0.20:8765", home: home, lookup: lookup) == nil)
    }

    /// **The key goes to the number that named its file, and never to the name again**, as in the app
    /// (`OwnerMacKey.signing`): a hub that is called by a name is looked up once, the call with the key goes to that
    /// number, and the same call with no key goes as its address is written.
    @Test func aCallWithTheKeyGoesToTheHubsNumberAndNeverToItsName() throws {
        let numbered = Self.hub(), home = home
        let named = StandInHub(features: Fixture.everyFeature, host: "hub-\(UUID().uuidString.lowercased().prefix(8)).tail1234.ts.net")
        asking(numbered, for: Self.key)
        try keep(Self.key, for: numbered)
        let number = numbered.host
        #expect(OwnerComputerKey.find(base: named.base, home: home, lookup: { _ in number })?.address == number)
        #expect(OwnerComputerKey.find(base: named.base, home: home, lookup: { _ in "100.64.0.99" }) == nil)
        func client() -> OwnerHub {
            OwnerHub(base: named.base, transport: Fixture.transport(), userAgent: "founderizer-cli/test",
                     clientLabel: { "founderizer-cli/1/test" }, lockFile: nil,
                     ownerKey: { OwnerComputerKey.find(base: $0, home: home, lookup: { _ in number }) })
        }
        #expect(try client().call("GET", "/ui/state?db=g1").status == 200)
        #expect(numbered.seen.map { $0.header("Authorization") } == ["Bearer " + Self.key])
        #expect(numbered.seen.first?.path == "/ui/state")
        #expect(numbered.seen.first?.query == "db=g1")
        #expect(named.seen.isEmpty)
        // A hub from before the key refuses the bearer: the call with no key goes as its address is written.
        asking(numbered, for: nil)
        #expect(try client().call("GET", "/ui/state").status == 200)
        #expect(numbered.seen.count == 2)
        #expect(named.seen.map { $0.header("Authorization") } == [nil])
        #expect(OwnerComputerKey.numbered(URL(string: "http://hub.example:8765/ui/x?a=1")!, address: "fd7a:115c:a1e0::1")?.absoluteString
                == "http://[fd7a:115c:a1e0::1]:8765/ui/x?a=1")
    }

    /// As in the app (`OwnerMacKey.canonical`, `OwnerMacKey.chosen`): one spelling for an address, and one number for
    /// a name with two addresses, in whatever order a resolver gives them.
    @Test func oneAddressHasOneSpellingAndANameWithTwoAddressesHasOneNumber() throws {
        #expect(OwnerComputerKey.canonical("100.64.0.9") == "100.64.0.9")
        #expect(OwnerComputerKey.canonical("FD7A:115C:A1E0:0:0:0:0:1") == "fd7a:115c:a1e0::1")
        #expect(OwnerComputerKey.canonical("hub.example") == nil && OwnerComputerKey.canonical("") == nil)
        #expect(OwnerComputerKey.chosen(["192.0.2.28", "100.64.0.9", "fd7a:115c:a1e0::1"]) == "100.64.0.9")
        #expect(OwnerComputerKey.chosen(["fd7a:115c:a1e0::1", "100.64.0.9", "192.0.2.28"]) == "100.64.0.9")
        #expect(OwnerComputerKey.chosen(["192.0.2.28", "192.0.2.5"]) == "192.0.2.5")
        #expect(OwnerComputerKey.chosen(["192.0.2.5", "192.0.2.28"]) == "192.0.2.5")
        #expect(OwnerComputerKey.chosen(["100.64.0.10", "100.64.0.9"]) == "100.64.0.9")
        #expect(OwnerComputerKey.chosen(["10.0.0.9", "100.64.0.9"]) == "100.64.0.9")       // also where it is not the lowest
        #expect(OwnerComputerKey.chosen(["100.64.0.9", "10.0.0.9"]) == "100.64.0.9")
        #expect(OwnerComputerKey.chosen(["fd7a:115c:a1e0::2", "FD7A:115C:A1E0::1"]) == "fd7a:115c:a1e0::1")
        #expect(OwnerComputerKey.chosen([]) == nil && OwnerComputerKey.chosen(["not an address"]) == nil)
        // The long spelling of an address reads the file of the short one, and its keyed call goes to the short one.
        try OwnerMacKey.keep(Self.key, hub: try #require(URL(string: "http://[fd7a:115c:a1e0::1]:8765")), home: home)
        let found = try #require(OwnerComputerKey.find(base: "http://[fd7a:115c:a1e0:0:0:0:0:1]:8765", home: home))
        #expect(found.key == Self.key && found.address == "fd7a:115c:a1e0::1")
        #expect(OwnerComputerKey.numbered(URL(string: "http://[fd7a:115c:a1e0:0:0:0:0:1]:8765/ui/x")!, address: found.address)?.absoluteString
                == "http://[fd7a:115c:a1e0::1]:8765/ui/x")
    }

    @Test func aFileThatHoldsNoKeyIsNoKey() throws {
        let hub = Self.hub()
        let folder = home.appendingPathComponent(".founderizer/owner-keys", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = try #require(OwnerComputerKey.name(base: hub.base))
        for text in ["", "short", "words that are no key", String(repeating: "a", count: 300)] {
            try Data(text.utf8).write(to: folder.appendingPathComponent(name))
            #expect(OwnerComputerKey.read(base: hub.base, home: home) == nil)
        }
        try Data((Self.key + "\n").utf8).write(to: folder.appendingPathComponent(name))
        #expect(OwnerComputerKey.read(base: hub.base, home: home) == Self.key)
        #expect(OwnerComputerKey.read(base: "http://other.example.com:8765", home: home, lookup: { _ in nil }) == nil)
    }
}
