import CryptoKit
import Foundation
import Testing
@testable import FleetCore

/// **The record `server-made`** (F17 design A, SP1): the text and the signature that this Mac writes are the ones that
/// the hub and the vault check (`app/vectors/server-made.json`, made with `vault.canonical` and `vault.owner_signed`),
/// and a reader counts a record of the hub's only by a key of its own anchors (the validator's N8).
struct ServerMadeTests {
    private static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("vectors")

    private func vector() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.folder.appendingPathComponent("server-made.json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func signer(_ v: [String: Any]) throws -> SoftwareOwnerKey {
        let hex = try #require(v["private_scalar_hex"] as? String)
        var bytes = [UInt8](), index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(try #require(UInt8(hex[index..<next], radix: 16)))
            index = next
        }
        return SoftwareOwnerKey(try P256.Signing.PrivateKey(rawRepresentation: Data(bytes)))
    }

    private func made(_ v: [String: Any]) throws -> ServerMade.Fields {
        let fields = try #require(v["fields"] as? [String: Any])
        let machine = try #require(fields["machine"] as? String), id = try #require(fields["id"] as? String)
        let providerName = try #require(fields["provider"] as? String), useName = try #require(fields["use"] as? String)
        let provider = try #require(CloudProvider(rawValue: providerName))
        let use = try #require(CloudServerUse(rawValue: useName))
        return try #require(ServerMade.Fields(machine: machine, provider: provider, id: id, use: use))
    }

    /// The Mac's text of the vector's server is the hub's byte for byte, its `by` is the vault's form, and the
    /// signature that Python made counts. A bug here: the Mac signs a text, or names its key, in a form that the hub,
    /// the vault and the keeper read otherwise, and no record of this Mac ever counts anywhere.
    @Test func theTextAndTheByAreTheHubsAndItsSignatureCounts() throws {
        let v = try vector()
        let fleet = try #require(v["fleet"] as? String), statement = try #require(v["statement"] as? String)
        let fields = try #require(v["fields"] as? [String: Any])
        let at = try #require(fields["at"] as? NSNumber).intValue
        let server = try made(v), signature = try #require(v["signature"] as? String)
        #expect(OwnerStatement.serverMade(fleet: fleet, made: server, at: at) == statement)
        #expect(ServerMade.fields(of: statement, fleet: fleet) == server)
        let publicKey = try #require(v["public_key"] as? String)
        #expect(ServerMade.by(publicKey) == v["by"] as? String)
        #expect(ServerMade.verifies(statement, signature: signature, key: publicKey))
        let key = try signer(v)
        #expect(key.publicKey == publicKey)
        let mine = try ServerMade.Signed.sign(server, fleet: fleet, key: key, at: at)
        #expect(mine.statement == statement && mine.key == publicKey && server.server == "hetzner|58213977")
        #expect(ServerMade.verifies(mine.statement, signature: mine.signature, key: publicKey))
    }

    /// Each signature and each text that the vault refuses is no record here either, and a record of another fleet is
    /// none: a reader that took one would count a record that the keeper refuses, or a proof of another fleet's server.
    @Test func eachRefusedSignatureAndTextIsNoRecord() throws {
        let v = try vector()
        let fleet = try #require(v["fleet"] as? String), statement = try #require(v["statement"] as? String)
        let publicKey = try #require(v["public_key"] as? String)
        for item in try #require(v["refused_signatures"] as? [[String: Any]]) {
            let signature = try #require(item["signature"] as? String)
            #expect(!ServerMade.verifies(statement, signature: signature, key: publicKey), "\(item["name"] ?? "")")
        }
        let refused = try #require(v["refused_statements"] as? [[String: Any]])
        #expect(refused.count >= 10)
        for item in refused {
            let text = try #require(item["statement"] as? String)
            #expect(ServerMade.fields(of: text, fleet: fleet) == nil, "\(item["name"] ?? "")")
        }
        let other = try #require(v["other_public_key"] as? String)
        #expect(ServerMade.by(other) != v["by"] as? String)
        #expect(ServerMade.by("not a key") == nil)
    }

    /// **N8: the hub's row is no proof.** A record counts only when the key that its `by` names in the reader's own
    /// anchors signed its text: a row whose `key` the hub chose, whose `by` names the reader's key and whose signature
    /// that other key made, proves nothing, and neither does a record of a key that the reader does not hold. A bug
    /// here: a hub that is broken into writes the id of another business's server, and a reader that deletes by such a
    /// record (the keeper of design A's SP7) deletes that server.
    @Test func aRecordCountsOnlyByAKeyOfTheReadersOwnAnchors() throws {
        let v = try vector()
        let fleet = try #require(v["fleet"] as? String), publicKey = try #require(v["public_key"] as? String)
        let by = try #require(v["by"] as? String)
        let server = try made(v), key = try signer(v)
        let own = try ServerMade.Signed.sign(server, fleet: fleet, key: key)
        let stranger = SoftwareOwnerKey()
        let other = try #require(ServerMade.Fields(machine: "worker-4", provider: .hetzner, id: "58213990", use: .agent))
        let forged = try ServerMade.Signed.sign(other, fleet: fleet, key: stranger)
        let strangerBy = try #require(ServerMade.by(stranger.publicKey))
        let records = [
            ServerMade.Record(statement: own.statement, signature: own.signature, key: own.key, by: by, received: 1),
            // The hub names the reader's key in `by`, and the stranger's in `key`, which signed the text.
            ServerMade.Record(statement: forged.statement, signature: forged.signature, key: stranger.publicKey, by: by,
                              received: 2),
            ServerMade.Record(statement: forged.statement, signature: forged.signature, key: stranger.publicKey,
                              by: strangerBy, received: 3),
        ]
        #expect(ServerMade.counted(records, fleet: fleet, anchors: [publicKey]).map(\.server) == ["hetzner|58213977"])
        #expect(ServerMade.counted(records, fleet: fleet, anchors: []).isEmpty)
        #expect(ServerMade.counted(records, fleet: "fedcba9876543210", anchors: [publicKey]).isEmpty)
        // With the stranger's key among the anchors, its record counts: the anchors decide, not the row.
        #expect(Set(ServerMade.counted(records, fleet: fleet, anchors: [publicKey, stranger.publicKey]).map(\.server))
                == ["hetzner|58213977", "hetzner|58213990"])
    }
}
