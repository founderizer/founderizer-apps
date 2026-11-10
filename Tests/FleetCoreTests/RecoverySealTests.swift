import CryptoKit
import Foundation
import Testing
@testable import FleetCore

/// DevOps plan V12 (the coordinator, 6 November 2026): the Mac seals the recovery code to the phone's own recovery key
/// once that key's binding matched its QR, and only that key opens the box, for that device's name.
struct RecoverySealTests {
    @Test func onlyThePhonesKeyOpensItsBoxForItsName() throws {
        let phone = P256.KeyAgreement.PrivateKey()
        let key = phone.publicKey.x963Representation.base64EncodedString()
        let code = Data("ABCD-EFGH-JKLM-NPQR-STUV-WX".utf8)
        let box = try RecoverySeal.seal(code, to: key, device: "iphone")
        #expect(!box.contains("ABCD"))
        let opened = try RecoverySeal.open(box, device: "iphone") { try phone.sharedSecretFromKeyAgreement(with: $0) }
        #expect(opened == code)
        #expect(throws: RecoverySeal.Failure.box) {
            try RecoverySeal.open(box, device: "iphone-2") { try phone.sharedSecretFromKeyAgreement(with: $0) }
        }
        let other = P256.KeyAgreement.PrivateKey()
        #expect(throws: RecoverySeal.Failure.box) {
            try RecoverySeal.open(box, device: "iphone") { try other.sharedSecretFromKeyAgreement(with: $0) }
        }
        var raw = try #require(Data(base64Encoded: box))
        raw[raw.count - 1] ^= 1
        #expect(throws: RecoverySeal.Failure.box) {
            try RecoverySeal.open(raw.base64EncodedString(), device: "iphone") { try phone.sharedSecretFromKeyAgreement(with: $0) }
        }
        #expect(throws: RecoverySeal.Failure.key) { try RecoverySeal.seal(code, to: "AAAA", device: "iphone") }
        #expect(try RecoverySeal.seal(code, to: key, device: "iphone") != box)       // a new ephemeral key each time
    }

    @Test func thePhonesRecoveryKeyIsBoundToTheSameQRValue() throws {
        let bind = DeviceBinding.newBind()
        let phone = P256.KeyAgreement.PrivateKey()
        let key = phone.publicKey.x963Representation.base64EncodedString()
        let binding = try #require(DeviceBinding.binding(bind: bind, key: key))
        #expect(DeviceBinding.binding(bind: DeviceBinding.newBind(), key: key) != binding)
        let json = """
        {"devices": [{"device": "iphone", "label": "iPhone", "address": "100.64.0.9", "key": true, "certified": false,
          "signing_key": "\(key)", "binding": "\(binding)", "recovery_key": "\(key)", "recovery_binding": "\(binding)",
          "recovery": null},
         {"device": "ipad", "label": "iPad", "address": "100.64.0.10", "key": true, "certified": true,
          "recovery_key": "\(key)", "recovery_binding": "\(binding)", "recovery": {"sealed": false, "held": 1.5}},
         {"device": "old", "label": "Old", "address": "100.64.0.11", "key": true}]}
        """
        struct List: Decodable { let devices: [OwnerDevice] }
        let list = try JSONDecoder().decode(List.self, from: Data(json.utf8))
        #expect(list.devices.map(\.wantsRecoveryCopy) == [true, false, false])
        #expect(list.devices[1].recovery == OwnerDevice.RecoveryCopyState(sealed: false, held: 1.5))
    }
}
