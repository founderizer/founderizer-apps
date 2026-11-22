import Foundation
import Testing
@testable import FleetCore

/// **The owner's record of an item in a cluster's store** (`OwnerStatement.storeKey`, `StoreKeyRecord.kept`).
/// Synthetic values only.
struct StoreKeyRecordTests {
    static let fleet = "0123456789abcdef"
    static let remote = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    /// The hub and the door parse the statement with Python's canonical JSON. The bug: a field of another name or
    /// spelling, so the hub refuses each record, or the door passes none.
    @Test func theStatementIsPythonsCanonicalJSONOfItsTwelveFields() {
        #expect(OwnerStatement.storeKey(fleet: Self.fleet, need: 42, agent: "devops", repo: "acme/gitops",
                                        storeKind: "ClusterSecretStore", store: "main", namespace: "shop",
                                        name: "stripe-key-a1b2c3", remote: Self.remote, at: 1_795_000_000)
                == #"{"agent":"devops","at":1795000000,"fleet":"0123456789abcdef","kind":"store-key","name":"stripe-key-a1b2c3","namespace":"shop","need":42,"remote":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","repo":"acme/gitops","store":"main","store_kind":"ClusterSecretStore","v":1}"#)
    }

    private func record(_ key: SoftwareOwnerKey, fleet: String = fleet, at: Int = 1_795_000_000,
                        statement: String? = nil, change: (inout [String: Any]) -> Void = { _ in }) throws -> StoreKeyRecord {
        let text = statement ?? OwnerStatement.storeKey(fleet: fleet, need: 42, agent: "devops", repo: "acme/gitops",
                                                         storeKind: "ClusterSecretStore", store: "main", namespace: "shop",
                                                         name: "stripe-key-a1b2c3", remote: Self.remote, at: at)
        var fields: [String: Any] = ["repo": "acme/gitops", "store_kind": "ClusterSecretStore", "store": "main",
                                     "remote": Self.remote, "namespace": "shop", "name": "stripe-key-a1b2c3",
                                     "agent": "devops", "need": 42, "statement": text, "signature": try key.sign(text)]
        change(&fields)
        return try JSONDecoder().decode(StoreKeyRecord.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    /// The door round writes only a record that this Mac's owner key signed, of exactly its own fields, into its own
    /// agent's own target. The bug: a row that the hub made up or changed reaches the door, or a record moves to
    /// another agent, repository, namespace or item.
    @Test func onlyTheOwnersStatementOfTheRecordsOwnFieldsIsKept() throws {
        let owner = SoftwareOwnerKey()
        func kept(_ record: StoreKeyRecord, agent: String = "devops", repo: String = "acme/gitops") -> Bool {
            record.kept(ownerKey: owner.publicKey, fleet: Self.fleet, agent: agent, repo: repo)
        }
        #expect(kept(try record(owner)))
        #expect(!kept(try record(owner), agent: "builder"))
        #expect(!kept(try record(owner), repo: "acme/other"))
        #expect(!kept(try record(SoftwareOwnerKey())))
        #expect(!kept(try record(owner, fleet: "fedcba9876543210")))
        for (key, value) in [("remote", "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"), ("namespace", "admin"),
                             ("name", "other-key-a1b2c3"), ("store", "other"), ("store_kind", "SecretStore"),
                             ("need", 43 as Any), ("agent", "builder")] {
            #expect(!kept(try record(owner) { $0[key] = value }, agent: key == "agent" ? "builder" : "devops"), "\(key)")
        }
        // A statement with one more field, or with another kind, is no statement of this record.
        let extra = #"{"agent":"devops","at":1795000000,"extra":"x","fleet":"0123456789abcdef","kind":"store-key","name":"stripe-key-a1b2c3","namespace":"shop","need":42,"remote":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","repo":"acme/gitops","store":"main","store_kind":"ClusterSecretStore","v":1}"#
        #expect(!kept(try record(owner, statement: extra)))
        let pin = OwnerStatement.pin(fleet: Self.fleet, machine: "devops", recipient: "age1x", at: 1_795_000_000)
        #expect(!kept(try record(owner, statement: pin)))
        // Another record's signature on this statement.
        let other = try record(owner, at: 1_795_000_001)
        #expect(!kept(try record(owner) { $0["signature"] = other.signature }))
    }
}
