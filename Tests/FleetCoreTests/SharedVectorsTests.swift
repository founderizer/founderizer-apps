import CryptoKit
import Foundation
import Testing
@testable import FleetCore

/// **The shared vectors of `app/vectors`**, which `make_vectors.py` made with the hub's own code (`vault.canonical`,
/// `vault.owner_signed`, `releases.py`, `autopublish.app_text`, `hub.device_signing`). The C# tests of the Windows app
/// (`windows/Founderizer.Core.Tests`) read the same files, so the Mac, the PC and the hub write and check the same bytes.
struct SharedVectorsTests {
    private static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("vectors")

    private func vector(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.folder.appendingPathComponent(name))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// Each flat case (text and whole numbers, the statements' values) is the text of the Mac's statement writer, byte
    /// for byte: the character classes that the .NET writer gets wrong, and the key order by code point.
    @Test func eachFlatCanonicalCaseIsTheStatementWritersText() throws {
        let cases = try #require(vector("canonical-json.json")["cases"] as? [[String: Any]])
        var flat = 0
        for item in cases where item["flat"] as? Bool == true {
            let name = item["name"] as? String ?? ""
            let object = try #require(item["object"] as? [String: Any])
            var fields: [String: OwnerStatement.Value] = [:]
            for (key, value) in object {
                if let text = value as? String {
                    fields[key] = .text(text)
                } else if let number = value as? NSNumber, !CFNumberIsFloatType(number) {
                    fields[key] = .number(number.intValue)
                } else {
                    Issue.record("\(name): \(key) is neither text nor a whole number")
                }
            }
            let text = OwnerStatement.canonical(fields)
            #expect(text == item["canonical"] as? String, "\(name)")
            #expect(hex(Data(text.utf8)) == item["utf8_hex"] as? String, "\(name)")
            flat += 1
        }
        #expect(flat >= 10)
    }

    /// The owner statement is the builder's text, its signature verifies, and a software key of the vector's scalar has
    /// its public key and signs what verifies.
    @Test func theOwnerStatementIsTheBuildersTextAndItsSignatureVerifies() throws {
        let v = try vector("owner-statement.json")
        let fields = try #require(v["fields"] as? [String: Any])
        let statement = try #require(v["statement"] as? String)
        let at = try #require(fields["at"] as? NSNumber).intValue
        #expect(OwnerStatement.ownerDevice(fleet: try #require(fields["fleet"] as? String),
                                           device: try #require(fields["device"] as? String),
                                           key: try #require(fields["key"] as? String), at: at) == statement)
        let publicKey = try #require(v["public_key"] as? String)
        let point = try #require(Data(base64Encoded: publicKey))
        let key = try P256.Signing.PublicKey(x963Representation: point)
        let signatureText = try #require(v["signature"] as? String)
        let der = try #require(Data(base64Encoded: signatureText))
        #expect(key.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: der), for: Data(statement.utf8)))
        #expect(!key.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: der), for: Data((statement + " ").utf8)))
        let scalarText = try #require(v["private_scalar_hex"] as? String)
        let scalar = try #require(Data(hexString: scalarText))
        let owner = SoftwareOwnerKey(try P256.Signing.PrivateKey(rawRepresentation: scalar))
        #expect(owner.publicKey == publicKey)
        let mineText = try owner.sign(statement)
        let mine = try P256.Signing.ECDSASignature(derRepresentation: try #require(Data(base64Encoded: mineText)))
        #expect(key.isValidSignature(mine, for: Data(statement.utf8)))
    }

    @Test func theDeviceBindingIsTheHMACOfTheKeyUnderTheQRsValue() throws {
        let v = try vector("device-binding.json")
        let bind = try #require(v["bind"] as? String)
        #expect(DeviceBinding.binding(bind: bind, key: try #require(v["key"] as? String)) == v["binding"] as? String)
        #expect(DeviceBinding.binding(bind: bind, key: try #require(v["recovery_key"] as? String))
                == v["recovery_binding"] as? String)
    }

    /// A build's manifest verifies with the app's own check, its signed text is the hub's, and each refused manifest is
    /// refused; the key file reads as the hub reads it.
    @Test func theAppsManifestVerifiesAndEachRefusedOneIsRefused() throws {
        let v = try vector("release-manifests.json")
        let app = try #require(v["app"] as? [String: Any])
        let channel = try #require(app["channel"] as? String)
        let keys = AppUpdate.keys(v["keys_text"] as? String)
        #expect(keys.map { $0.base64EncodedString() } == [v["public_key"] as? String])
        for text in try #require(v["keys_text_refused"] as? [String]) { #expect(AppUpdate.keys(text).isEmpty, "\(text)") }
        let data = try JSONSerialization.data(withJSONObject: try #require(app["manifest"]))
        let manifest = try AppUpdate.check(data, keys: keys, channel: channel)
        #expect(String(decoding: AppUpdate.signedText(manifest), as: UTF8.self) == app["signed_text"] as? String)
        let otherText = try #require(v["other_public_key"] as? String)
        let other = [try #require(Data(base64Encoded: otherText))]
        #expect(throws: AppUpdateUntrusted.self) { try AppUpdate.check(data, keys: other, channel: channel) }
        for refused in try #require(app["refused"] as? [[String: Any]]) {
            let bytes = try JSONSerialization.data(withJSONObject: try #require(refused["manifest"]))
            #expect(throws: AppUpdateUntrusted.self, "\(refused["name"] ?? "")") {
                try AppUpdate.check(bytes, keys: keys, channel: channel)
            }
        }
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
