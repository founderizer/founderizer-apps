import Foundation
import Testing
@testable import FleetVaultCore

/// Sealed copies: provenance (owner API 1.10). Fake data only: no Keychain, no Bitwarden, no hub.
struct VaultProvenanceTests {
    private let salts = ["password": "0123456789abcdef0123456789abcdef", "totp": "fedcba9876543210fedcba9876543210"]
    private let source = "bws://12345678-1234-1234-1234-123456789012"
    private let other = "bws://87654321-4321-4321-4321-210987654321"

    private func payload(_ fleet: Any?) throws -> Data {
        var object: [String: Any] = ["username": "synthetic-user", "password": "SYNTHETIC-PASSWORD", "url": "https://shop.example.test"]
        if let fleet { object["fleet"] = fleet }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func theConfirmationSaysThatThisBrokerChecksProvenance() throws {
        let request = try VaultRequest(data: Data(#"{"v":2,"op":"handover","job":12}"#.utf8))
        let body = try #require(JSONSerialization.jsonObject(with: VaultHub.confirmBody(request)) as? [String: Any])
        #expect(Set(body.keys) == ["job", "kind", "provenance"])
        #expect(body["job"] as? Int == 12 && body["kind"] as? String == "handover" && body["provenance"] as? Int == 1)
        let probe = try VaultRequest(data: Data(#"{"v":2,"op":"probe","job":12}"#.utf8))
        #expect(throws: VaultFailure.self) { try VaultHub.confirmBody(probe) }
    }

    @Test func theJobNamesItsProjectAndSourceOrNothing() throws {
        let request = try VaultRequest(data: Data(#"{"v":2,"op":"signin","job":12}"#.utf8))
        var grant: [String: Any] = ["ok": true, "kind": "signin", "job": 12, "task": "T-1", "login": source, "fingerprint_salts": salts]
        let plain = try VaultJob(data: JSONSerialization.data(withJSONObject: grant), request: request)
        #expect(plain.project == nil && plain.source == nil)
        grant["project"] = "shop"; grant["source"] = source
        let scoped = try VaultJob(data: JSONSerialization.data(withJSONObject: grant), request: request)
        #expect(scoped.project == "shop" && scoped.source == source)
        for (key, value) in [("project", "Shop!" as Any), ("project", 7 as Any), ("source", "sealed:3" as Any), ("source", true as Any)] {
            var bad = grant; bad[key] = value
            #expect(throws: VaultFailure.hub) { try VaultJob(data: JSONSerialization.data(withJSONObject: bad), request: request) }
        }
    }

    @Test func theHubRecordOfACopyIsCheckedForItsTypes() throws {
        #expect(try SealedRecord(object: ["job": 12, "project": "shop", "source": source]) == SealedRecord(job: 12, project: "shop", source: source))
        #expect(try SealedRecord(object: ["job": NSNull(), "project": NSNull(), "source": NSNull()]) == SealedRecord(job: nil, project: nil, source: nil))
        #expect(try SealedRecord(object: [:]) == SealedRecord(job: nil, project: nil, source: nil))
        for bad: [String: Any] in [["job": true], ["job": "12"], ["job": 0], ["project": "Shop"], ["source": "file:/tmp/x"]] {
            #expect(throws: VaultFailure.handover) { try SealedRecord(object: bad) }
        }
    }

    @Test func aCopyIsUsedOnlyWithTheProvenanceThatTheHubRecorded() throws {
        let record = SealedRecord(job: 12, project: "shop", source: source)
        let made = VaultProvenance.stamp(job: 12, project: "shop", source: source)
        #expect(try VaultProvenance.check(payload: payload(made), record: record, usingProject: "shop") == source)
        // The relabelled replay: a copy made under one handover, sent again under another job, project or source.
        for (fleet, record, using) in [
            (made, SealedRecord(job: 13, project: "shop", source: source), "shop"),                 // another job
            (made, SealedRecord(job: 12, project: "blog", source: source), "blog"),                 // another project
            (made, SealedRecord(job: 12, project: "shop", source: other), "shop"),                  // another source
            (made, record, "blog"),                                                                 // used in another project
            (made, record, nil),                                                                    // used outside the project
            (made.merging(["v": 2]) { _, b in b }, record, "shop"),
            (made.merging(["job": true]) { _, b in b }, record, "shop"),
            (made.merging(["extra": 1]) { _, b in b }, record, "shop"),
            (["v": 1, "job": 12, "project": "shop"] as [String: Any], record, "shop"),              // a field missing
            (made.merging(["project": NSNull()]) { _, b in b }, record, "shop")
        ] as [([String: Any], SealedRecord, String?)] {
            #expect(throws: VaultFailure.relabelledCopy) { try VaultProvenance.check(payload: payload(fleet), record: record, usingProject: using) }
        }
        #expect(throws: VaultFailure.relabelledCopy) {
            try VaultProvenance.check(payload: payload("not an object"), record: record, usingProject: "shop")
        }
    }

    @Test func aCopyWithoutProvenanceIsUsedOnlyOutsideProjects() throws {
        let none = SealedRecord(job: nil, project: nil, source: nil)
        #expect(try VaultProvenance.check(payload: payload(nil), record: none, usingProject: nil) == nil)
        #expect(try VaultProvenance.check(payload: payload(NSNull()), record: none, usingProject: nil) == nil)
        #expect(throws: VaultFailure.unscopedCopy) { try VaultProvenance.check(payload: payload(nil), record: none, usingProject: "shop") }
        #expect(throws: VaultFailure.unscopedCopy) {
            try VaultProvenance.check(payload: payload(nil), record: SealedRecord(job: 4, project: "shop", source: source), usingProject: nil)
        }
        let outside = VaultProvenance.stamp(job: 9, project: nil, source: source)      // a 1.10 copy outside projects
        #expect(try VaultProvenance.check(payload: payload(outside), record: SealedRecord(job: 9, project: nil, source: source),
                                          usingProject: nil) == source)
    }

    @Test func aNewCopyCarriesItsProvenanceAndStaysAValidLogin() throws {
        let login = try VaultLogin(data: payload(nil), label: "Shop admin")
        let sealed = try login.sealedPayload(provenance: VaultProvenance.stamp(job: 12, project: "shop", source: source))
        let object = try #require(JSONSerialization.jsonObject(with: sealed) as? [String: Any])
        let fleet = try #require(object["fleet"] as? [String: Any])
        #expect(fleet["v"] as? Int == 1 && fleet["job"] as? Int == 12 && fleet["project"] as? String == "shop" && fleet["source"] as? String == source)
        let opened = try VaultLogin(data: sealed, label: "Shop admin")              // the login is the payload without fleet
        #expect(opened.username == "synthetic-user" && opened.password == "SYNTHETIC-PASSWORD")
        #expect(try VaultProvenance.check(payload: sealed, record: SealedRecord(job: 12, project: "shop", source: source), usingProject: "shop") == source)
        let outside = try login.sealedPayload(provenance: VaultProvenance.stamp(job: 3, project: nil, source: nil))
        let empty = try #require((JSONSerialization.jsonObject(with: outside) as? [String: Any])?["fleet"] as? [String: Any])
        #expect(empty["project"] is NSNull && empty["source"] is NSNull)
    }
}
