import Foundation
import Testing
@testable import FleetImport

/// **Bitwarden's own test vectors** for the steps of a password-protected export, the only checks of `ExportCrypto` that
/// do not come from this code's own reading of the recipe. The numbers are those of the unit tests in
/// `bitwarden/sdk-internal` (commit 15db6b9f, `crates/bitwarden-crypto`): `keys/kdf.rs` (`test_master_key_derive_pbkdf2`
/// and `test_master_key_derive_argon2`), `keys/utils.rs` (`test_stretch_kdf_key`) and
/// `hazmat/symmetric_encryption/aes256_cbc_hmac_sha256_ae.rs` (`test_decrypt_testvector`). The password is the one that
/// those tests use, and it is no secret.
struct BitwardenVectorsTests {
    private let password = "67t9b5g67$%Dh89n", salt = "test_key"

    private let pbkdf2Key: [UInt8] = [31, 79, 104, 226, 150, 71, 177, 90, 194, 80, 172, 209, 17, 129, 132, 81, 138, 167,
                                      69, 167, 254, 149, 2, 27, 39, 197, 64, 42, 22, 195, 86, 75]

    @Test func thePBKDF2KeyIsBitwardens() throws {
        #expect(try ExportCrypto.passwordKey(password: password, salt: salt, kdf: 0, iterations: 10_000, memory: nil,
                                             parallelism: nil) == pbkdf2Key)
    }

    @Test func theArgon2idKeyIsBitwardens() throws {
        // 4 passes, 32 MiB, 2 lanes; the salt goes through SHA-256 first, as Bitwarden's own function does it.
        let expected: [UInt8] = [207, 240, 225, 177, 162, 19, 163, 76, 98, 106, 179, 175, 224, 9, 17, 240, 20, 147,
                                 237, 47, 246, 150, 141, 184, 62, 225, 131, 242, 51, 53, 225, 242]
        #expect(try ExportCrypto.passwordKey(password: password, salt: salt, kdf: 1, iterations: 4, memory: 32,
                                             parallelism: 2) == expected)
    }

    @Test func theStretchedKeysAreBitwardens() {
        let keys = ExportCrypto.stretch(pbkdf2Key)
        #expect(keys.enc == [111, 31, 178, 45, 238, 152, 37, 114, 143, 215, 124, 83, 135, 173, 195, 23, 142,
                             134, 120, 249, 61, 132, 163, 182, 113, 197, 189, 204, 188, 21, 237, 96])
        #expect(keys.mac == [221, 127, 206, 234, 101, 27, 202, 38, 86, 52, 34, 28, 78, 28, 185, 16, 48, 61, 127,
                             166, 209, 247, 194, 87, 232, 26, 48, 85, 193, 249, 179, 155])
    }

    @Test func aCipherTextOfBitwardensOwnIsOpened() throws {
        let iv: [UInt8] = [216, 218, 36, 0, 196, 186, 150, 85, 49, 147, 110, 168, 185, 227, 42, 172]
        let mac: [UInt8] = [60, 78, 44, 111, 72, 233, 3, 6, 86, 250, 217, 242, 62, 229, 184, 221, 231, 150, 189, 44,
                            99, 189, 220, 55, 196, 194, 101, 60, 102, 195, 149, 130]
        let data: [UInt8] = [234, 77, 16, 15, 189, 82, 36, 188, 182, 88, 64, 67, 145, 94, 30, 178, 36, 235, 130, 67,
                             255, 207, 183, 168, 73, 231, 82, 122, 193, 139, 25, 129]
        // The key of the vector is the bytes 0 to 63: the encryption key first and the MAC key second.
        let enc = (0 ..< 32).map { UInt8($0) }, key = (32 ..< 64).map { UInt8($0) }
        func text(_ b: [UInt8]) -> String { Data(b).base64EncodedString() }
        let sealed = "2." + text(iv) + "|" + text(data) + "|" + text(mac)
        #expect(String(decoding: try ExportCrypto.open(sealed, enc: enc, mac: key), as: UTF8.self) == "Bitwarden SDK test vector")
        // One changed byte of the data is refused before anything is decrypted.
        var changed = data
        changed[0] ^= 1
        #expect(throws: ExportCrypto.Failure.password) {
            try ExportCrypto.open("2." + text(iv) + "|" + text(changed) + "|" + text(mac), enc: enc, mac: key)
        }
    }
}
