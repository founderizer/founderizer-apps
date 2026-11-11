import CryptoKit
import Foundation
import Testing
@testable import FleetImport

private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

/// The vectors come from other implementations: Python's hashlib (BLAKE2b), RFC 9106 section 5.3, and Python's
/// `cryptography` (OpenSSL) for Argon2id. None of them was made with this code.
struct Argon2Tests {
    @Test func blake2bMatchesHashlib() {
        #expect(hex(Blake2b.hash(Array("abc".utf8))) == "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
        #expect(hex(Blake2b.hash([])) == "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce")
        let long = (0 ..< 3).flatMap { _ in (0 ..< 256).map { UInt8($0) } }
        #expect(hex(Blake2b.hash(long, length: 32)) == "b8007121274217790e2923e0ad7027986e5a99d5531ef6ae7d294140fc81615d")
        #expect(hex(Blake2b.hash([UInt8](repeating: 0, count: 128))) == "865939e120e6805438478841afb739ae4250cf372653078a065cdcfffca4caf798e6d462b65d658fc165782640eded70963449ae1500fb0f24981d7727e22c41")
    }

    @Test func argon2idMatchesRFC9106() throws {
        let tag = try Argon2id.derive(password: [UInt8](repeating: 1, count: 32), salt: [UInt8](repeating: 2, count: 16),
                                      iterations: 3, memory: 32, parallelism: 4, length: 32,
                                      secret: [UInt8](repeating: 3, count: 8), associated: [UInt8](repeating: 4, count: 12))
        #expect(hex(tag) == "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")
    }

    @Test func argon2idMatchesOpenSSL() throws {
        // Made with Python's `cryptography` (OpenSSL): four lanes with a 32-byte salt, and two lanes with a long output.
        let salt = Array(SHA256.hash(data: Data("synthetic-salt-1".utf8)))
        #expect(hex(try Argon2id.derive(password: Array("pässwörd synthetic".utf8), salt: salt, iterations: 3, memory: 1024,
                                        parallelism: 4)) == "391846072b18176d5adf446b569543d048b35a1de0553a81be27adb1a1fcc7d2")
        #expect(hex(try Argon2id.derive(password: Array("x".utf8), salt: Array("abcdefgh".utf8), iterations: 1, memory: 64,
                                        parallelism: 2, length: 80))
                == "1308b48275b4aaa72fe572994b6fc81fc1dc982207c634e8bf32dda7d3cfda3405ea344c50bd15cac6f104a88eec6855d5d0a3381847c3208c70f82a9c11a99f520dfb3262a8ff9fee80e337d02f1f32")
    }

    @Test func badParametersAreRefused() {
        #expect(throws: Argon2id.Failure.self) { try Argon2id.derive(password: [], salt: Array("short".utf8), iterations: 1, memory: 64, parallelism: 1) }
        #expect(throws: Argon2id.Failure.self) { try Argon2id.derive(password: [], salt: Array("longsalt".utf8), iterations: 0, memory: 64, parallelism: 1) }
        #expect(throws: Argon2id.Failure.self) { try Argon2id.derive(password: [], salt: Array("longsalt".utf8), iterations: 1, memory: 2_000_000, parallelism: 1) }
    }
}
