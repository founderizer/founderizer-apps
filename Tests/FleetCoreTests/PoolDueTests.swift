import Foundation
import Testing
@testable import FleetCore

/// **The pool statements that the hub's default owes the central vault** (owner feature `pool_default`, owner API
/// 1.328). The owner's Mac signs them under the hood, so the manager can give each secret that the fleet holds with no
/// card. Bugs that this catches: the app reads no `standing.due` and the vault never seals a secret of the default; it
/// signs a reference that is no secret's; or the round signs a plain `pool`, which ends the owner's own `unpool` ("Only
/// you"), where the vault takes a `default_pool` only over no unpool (the Door area's read of 24 November 2026).
struct PoolDueTests {
    private static let login = "bws://11111111-2222-4333-8444-55555555555b"

    @Test func theReadingTakesWhatIsOwedAndNothingElse() throws {
        let json = """
        {"db": "gen", "fleet": null, "machines": [], "held": {},
         "standing": {"grants": [], "pool": [], "due": [{"login": "\(Self.login)", "in": true},
                                                         {"login": "not a reference", "in": true},
                                                         {"login": "\(Self.login)"}]}}
        """
        let reading = try JSONDecoder().decode(VaultReading.self, from: Data(json.utf8))
        #expect(reading.poolDue == [VaultPoolDue(login: Self.login, in: true)])
        // no standing (a status that is not fresh, or one read before the last statement): nothing is owed
        let stale = try JSONDecoder().decode(VaultReading.self, from: Data(#"{"db": "gen", "standing": null}"#.utf8))
        #expect(stale.poolDue.isEmpty)
    }

    @Test func theRoundSignsADefaultPoolThatTheVaultNeverTakesOverAnUnpool() throws {
        let statement = OwnerStatement.defaultPool(fleet: "fleet-1", login: Self.login.uppercased(), at: 1_800_000_000)
        #expect(statement == #"{"at":1800000000,"fleet":"fleet-1","kind":"default_pool","login":"\#(Self.login)","v":1}"#)
        // the round's own signature is of that kind: GrantSigning.pools passes byDefault: true, and only there
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Founderizer/GrantSigning.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(text.range(of: "static func pools("))
        let end = try #require(text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex))
        #expect(text[start.lowerBound..<end.lowerBound].contains("byDefault: true"))
        #expect(text.components(separatedBy: "byDefault: true").count == 2, "only the round signs a default_pool")
        // a refusal of one statement (no value yet, money, their unpool) never holds the rest of the round
        #expect(text[start.lowerBound..<end.lowerBound].contains(
            "} catch HubError.refusal(let refusal) where (400..<500).contains(refusal.status) {\n                continue"))
    }
}
