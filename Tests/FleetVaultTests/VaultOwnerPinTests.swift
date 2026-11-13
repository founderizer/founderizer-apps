import CryptoKit
import Foundation
import Testing
@testable import FleetVaultCore

/// The owner's pin of a handover's recipient on a Mac (`VaultOwnerPin`), checked as `vault.py` checks it on Linux.
/// Fake data only: keys made here, no Keychain, no store and no hub.
struct VaultOwnerPinTests {
    private let salts = ["password": "0123456789abcdef0123456789abcdef", "totp": "fedcba9876543210fedcba9876543210"]
    private let fleet = "0123456789abcdef"
    private let owner = P256.Signing.PrivateKey()
    private let recipient = "age1" + String(repeating: "q", count: 58)
    private let other = "age1" + String(repeating: "p", count: 58)
    private var ownerKey: String { owner.publicKey.x963Representation.base64EncodedString() }

    private func configuration(_ extra: [String: Any] = [:]) throws -> VaultConfiguration {
        let base: [String: Any] = ["agent": "studio", "hub": "http://100.96.10.20:8765", "store": "fleet", "worker_uid": 501,
                                   "socket": NSHomeDirectory() + "/Library/Application Support/AgentFleet/vault.sock"]
        return try VaultConfiguration(data: JSONSerialization.data(withJSONObject: base.merging(extra) { _, new in new }))
    }
    private var keyed: VaultConfiguration { get throws { try configuration(["owner_keys": [ownerKey], "fleet": fleet]) } }

    /// A pin statement in the app's spelling (`OwnerStatement.pin`): keys sorted, no white space.
    private func statement(fleet: String? = nil, machine: String = "worker-1", recipient: String? = nil, at: Int = 1_700_000_000) -> String {
        #"{"at":\#(at),"fleet":"\#(fleet ?? self.fleet)","kind":"pin","machine":"\#(machine)","recipient":"\#(recipient ?? self.recipient)","v":1}"#
    }
    private func sign(_ text: String, with key: P256.Signing.PrivateKey? = nil) throws -> String {
        try (key ?? owner).signature(for: Data(text.utf8)).derRepresentation.base64EncodedString()
    }
    private func job(pin: Any?, recipient: String? = nil, operation: String = "handover") throws -> VaultJob {
        var fields: [String: Any] = ["ok": true, "kind": operation, "job": 12, "task": "T-1",
                                     "login": "bws://12345678-1234-1234-1234-123456789012", "fingerprint_salts": salts]
        if operation == "handover" { fields["target"] = "seo"; fields["recipient"] = recipient ?? self.recipient }
        if let pin { fields["pin"] = pin }
        let request = try VaultRequest(data: Data(#"{"v":2,"op":"\#(operation)","job":12}"#.utf8))
        return try VaultJob(data: JSONSerialization.data(withJSONObject: fields), request: request)
    }
    private func signedPin(_ text: String? = nil) throws -> [String: Any] {
        let text = text ?? statement()
        return ["statement": text, "signature": try sign(text)]
    }

    @Test func theStatementIsTheAppsCanonicalText() {
        // OwnerStatement.pin writes this text for these fields, and vault.py's canonical() of its object is the same.
        #expect(VaultOwnerPin.canonical(["v": .number(1), "kind": .text("pin"), "fleet": .text(fleet), "machine": .text("worker-1"),
                                         "recipient": .text(recipient), "at": .number(1_700_000_000)]) == statement())
        #expect(VaultOwnerPin.quoted("a\"b\\c\n\u{01}é") == #""a\"b\\c\n\u0001é""#)
    }

    @Test func theConfigurationTakesTheOwnersKeysWithTheFleetOrNeither() throws {
        #expect(try configuration().ownerKeys == nil)
        #expect(try configuration().fleet == nil)
        let config = try keyed
        #expect(config.ownerKeys == [ownerKey] && config.fleet == fleet)
        let eight = (0..<8).map { _ in P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString() }
        #expect(try configuration(["owner_keys": eight, "fleet": fleet]).ownerKeys?.count == 8)

        let offCurve = Data([4] + [UInt8](repeating: 0, count: 64)).base64EncodedString()
        var nearly = owner.publicKey.x963Representation
        nearly[nearly.count - 1] ^= 1                       // the owner's x with another y: no point of the curve
        let offCurveToo = nearly.base64EncodedString()
        let short = Data([4] + [UInt8](repeating: 1, count: 63)).base64EncodedString()
        let compressed = owner.publicKey.compressedRepresentation.base64EncodedString()
        #expect(ownerKey.hasSuffix("="))                    // 65 bytes: 87 characters and one "="
        let unpadded = String(ownerKey.dropLast())
        let bad: [[String: Any]] = [
            ["owner_keys": [ownerKey]], ["fleet": fleet],                                   // one without the other
            ["owner_keys": NSNull(), "fleet": fleet], ["owner_keys": [ownerKey], "fleet": NSNull()],
            ["owner_keys": [], "fleet": fleet], ["owner_keys": eight + [ownerKey], "fleet": fleet],
            ["owner_keys": ownerKey, "fleet": fleet], ["owner_keys": [7], "fleet": fleet],
            ["owner_keys": [offCurve], "fleet": fleet], ["owner_keys": [offCurveToo], "fleet": fleet],
            ["owner_keys": [short], "fleet": fleet], ["owner_keys": [ownerKey], "fleet": fleet + "\n"],
            ["owner_keys": [compressed], "fleet": fleet], ["owner_keys": [unpadded], "fleet": fleet],
            ["owner_keys": [ownerKey + "\n"], "fleet": fleet],
            ["owner_keys": [ownerKey], "fleet": "0123456789ABCDEF"], ["owner_keys": [ownerKey], "fleet": "0123"],
            ["owner_keys": [ownerKey], "fleet": 12], ["owner_keys": [ownerKey], "fleet": fleet, "region": "eu"]]
        for extra in bad {
            #expect(throws: VaultFailure.self) { try configuration(extra) }
        }
    }

    @Test func aVaultWithTheOwnersKeysHandsOverOnlyToAKeyThatTheOwnerPinned() throws {
        let config = try keyed
        try VaultOwnerPin.check(try job(pin: try signedPin()), configuration: config)
        // The hub names another key than the one the owner pinned.
        #expect(throws: VaultFailure.ownerPinOther) {
            try VaultOwnerPin.check(try job(pin: try signedPin(), recipient: other), configuration: config)
        }
        // The hub carries no pin: none kept for that machine, or a broken-in hub that leaves it out.
        for pin: Any? in [nil, NSNull(), "a pin", ["statement": statement()], ["statement": 7, "signature": "x"]] {
            #expect(throws: VaultFailure.ownerPinMissing) { try VaultOwnerPin.check(try job(pin: pin), configuration: config) }
        }
        // A second key of the owner's signs as well as the first.
        let second = P256.Signing.PrivateKey()
        let two = try configuration(["owner_keys": [second.publicKey.x963Representation.base64EncodedString(), ownerKey], "fleet": fleet])
        try VaultOwnerPin.check(try job(pin: try signedPin()), configuration: two)
        let text = statement()
        try VaultOwnerPin.check(try job(pin: ["statement": text, "signature": try sign(text, with: second)]), configuration: two)
    }

    @Test func onlyTheOwnersCanonicalPinOfThisFleetCounts() throws {
        let config = try keyed
        let base = statement()
        var texts = [
            statement(fleet: "fedcba9876543210"),                                       // another fleet
            base.replacingOccurrences(of: #""kind":"pin""#, with: #""kind":"unpin""#),
            base.replacingOccurrences(of: #""v":1"#, with: #""v":2"#),
            base.replacingOccurrences(of: #""v":1"#, with: #""v":true"#),
            base.replacingOccurrences(of: #""v":1"#, with: #""v":1.0"#),
            base.replacingOccurrences(of: #""at":1700000000"#, with: #""at":-1"#),
            base.replacingOccurrences(of: #""at":1700000000"#, with: #""at":"1700000000""#),
            statement(machine: "Worker-1"), statement(machine: "-worker"), statement(recipient: "age1short"),
            statement(machine: #"worker-1\n"#), statement(machine: #"worker-1\r\n"#),
            statement(machine: "worker-1\u{2028}"), statement(recipient: recipient + #"\n"#),
            base.replacingOccurrences(of: ",", with: ", "),                             // not canonical: white space
            #"{"fleet":"\#(fleet)","at":1700000000,"kind":"pin","machine":"worker-1","recipient":"\#(recipient)","v":1}"#,   // order
            base.replacingOccurrences(of: #""v":1}"#, with: #""v":1,"x":"y"}"#),       // a field too many
            base.replacingOccurrences(of: #","machine":"worker-1""#, with: ""),        // a field too few
            base.replacingOccurrences(of: #""fleet":"0123"#, with: #""fleet":"\u0030123"#),   // an escape of its own
            base + " ", "[" + base + "]", "not json"]
        texts.append(base.replacingOccurrences(of: #""v":1}"#, with: #""v":1,"v":1}"#))   // a field twice
        for text in texts {
            #expect(throws: VaultFailure.ownerPinInvalid, "\(text)") {
                try VaultOwnerPin.check(try job(pin: ["statement": text, "signature": try sign(text)]), configuration: config)
            }
        }
        // The signature: another key's, over another text, not the owner's DER, or not the canonical base64.
        let stranger = try sign(base, with: P256.Signing.PrivateKey())
        let otherText = try sign(statement(at: 1_700_000_001))
        let raw = try owner.signature(for: Data(base.utf8)).rawRepresentation.base64EncodedString()
        let good = try sign(base)
        for signature in [stranger, otherText, raw, String(good.dropLast()), good + "\n", " " + good, "", "AAAA"] {
            #expect(throws: VaultFailure.ownerPinInvalid) {
                try VaultOwnerPin.check(try job(pin: ["statement": base, "signature": signature]), configuration: config)
            }
        }
    }

    @Test func withoutTheOwnersKeysAHandoverIsCheckedAsBefore() throws {
        // No Mac's configuration held the keys on 12 November 2026: such a vault refuses no handover for its pin.
        let config = try configuration()
        try VaultOwnerPin.check(try job(pin: nil), configuration: config)
        try VaultOwnerPin.check(try job(pin: ["statement": "not json", "signature": ""]), configuration: config)
        try VaultOwnerPin.check(try job(pin: try signedPin(), recipient: other), configuration: config)
    }

    @Test func theHubsPinIsReadOnlyWithAHandoverAndNeverStopsTheJobItself() throws {
        let pin = try signedPin()                           // a signature is new each time: compare with this one
        #expect(try job(pin: pin).pin == VaultOwnerPin.Signed(statement: statement(), signature: pin["signature"] as! String))
        #expect(try job(pin: "a pin").pin == nil)
        #expect(try job(pin: NSNull()).pin == nil)
        #expect(try job(pin: try signedPin(), operation: "signin").pin == nil)
    }
}


extension VaultCallerTests {
    /// A handover's job reaches the broker only through `VaultHub.confirm`, which checks the owner's pin first. So with
    /// the owner's keys a job without a valid pin never comes back to read, protect or seal a login, and the hub hears
    /// nothing of it after its one confirmation.
    @Test func aHandoverComesBackFromTheHubOnlyWithTheOwnersPin() async throws {
        let owner = P256.Signing.PrivateKey(), fleet = "0123456789abcdef", recipient = "age1" + String(repeating: "q", count: 58)
        let statement = #"{"at":1700000000,"fleet":"\#(fleet)","kind":"pin","machine":"worker-1","recipient":"\#(recipient)","v":1}"#
        let signature = try owner.signature(for: Data(statement.utf8)).derRepresentation.base64EncodedString()
        let hub = VaultHub(configuration: try VaultConfiguration(data: JSONSerialization.data(withJSONObject: [
            "agent": "studio", "hub": "http://100.64.0.1:9", "store": "fleet", "worker_uid": 501,      // no hub listens there
            "socket": NSHomeDirectory() + "/Library/Application Support/AgentFleet/vault.sock",
            "owner_keys": [owner.publicKey.x963Representation.base64EncodedString()], "fleet": fleet])), protocolClasses: [FakeHub.self])
        let request = try VaultRequest(data: Data(#"{"v":2,"op":"handover","job":12}"#.utf8))
        func answering(withPin: Bool, to key: String) {
            FakeHub.reset { _, _ in
                (200, ["ok": true, "kind": "handover", "job": 12, "task": "T-1", "login": "sealed:7", "target": "seo", "recipient": key,
                       "fingerprint_salts": ["password": "0123456789abcdef0123456789abcdef", "totp": "fedcba9876543210fedcba9876543210"],
                       "pin": withPin ? ["statement": statement, "signature": signature] as Any : NSNull()])
            }
        }
        answering(withPin: true, to: recipient)
        #expect(try await hub.confirm(request, as: VaultCaller(agent: "studio", key: nil)).recipient == recipient)
        answering(withPin: false, to: recipient)
        await #expect(throws: VaultFailure.ownerPinMissing) { try await hub.confirm(request, as: VaultCaller(agent: "studio", key: nil)) }
        #expect(FakeHub.seen.map(\.route) == ["/helper/vault/studio"])
        answering(withPin: true, to: "age1" + String(repeating: "p", count: 58))
        await #expect(throws: VaultFailure.ownerPinOther) { try await hub.confirm(request, as: VaultCaller(agent: "studio", key: nil)) }
        #expect(FakeHub.seen.map(\.route) == ["/helper/vault/studio"])
    }
}
