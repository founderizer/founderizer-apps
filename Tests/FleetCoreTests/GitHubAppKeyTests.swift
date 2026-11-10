import Foundation
import Security
import Testing
@testable import FleetCore

/// The GitHub App key that goes to the door (DevOps plan C5): this Mac signs the App's JWT with it, from either kind of
/// PEM file that GitHub downloads, before it asks GitHub whose App it is. The keys here are made by the test.
struct GitHubAppKeyTests {
    static func key() throws -> (SecKey, Data) {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let der = try #require(SecKeyCopyExternalRepresentation(key, nil) as Data?)
        return (key, der)
    }

    static func pem(_ der: Data, kind: String) -> String {
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(kind)-----\n\(body)\n-----END \(kind)-----\n"
    }

    /// The same key as PKCS#8: SEQUENCE { INTEGER 0, SEQUENCE { rsaEncryption, NULL }, OCTET STRING { key } }.
    static func pkcs8(_ pkcs1: Data) -> Data {
        func length(_ count: Int) -> [UInt8] {
            count < 0x80 ? [UInt8(count)] : count < 0x100 ? [0x81, UInt8(count)] : [0x82, UInt8(count >> 8), UInt8(count & 0xff)]
        }
        let algorithm: [UInt8] = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]
        let inner: [UInt8] = [0x02, 0x01, 0x00] + algorithm + [0x04] + length(pkcs1.count) + [UInt8](pkcs1)
        return Data([0x30] + length(inner.count) + inner)
    }

    static func verified(_ jwt: String, by key: SecKey) throws -> Bool {
        let parts = jwt.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        var base64 = parts[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        let signature = try #require(Data(base64Encoded: base64))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data("\(parts[0]).\(parts[1])".utf8) as CFData,
                                     signature as CFData, nil)
    }

    @Test func anRSAKeyFileSignsTheAppsJWT() throws {
        let (key, der) = try Self.key()
        let now = Date(timeIntervalSince1970: 1_762_000_000)
        let jwt = try GitHubAppKey.jwt(appID: "123456", pem: Self.pem(der, kind: "RSA PRIVATE KEY"), now: now)
        #expect(try Self.verified(jwt, by: key))
        let claims = jwt.split(separator: ".")[1]
        var base64 = claims.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        #expect(String(data: try #require(Data(base64Encoded: base64)), encoding: .utf8)
                    == #"{"exp":1762000540,"iat":1761999940,"iss":123456}"#)
    }

    @Test func aPKCS8KeyFileSignsTooAndAnythingElseIsRefused() throws {
        let (key, der) = try Self.key()
        #expect(GitHubAppKey.der(Self.pem(Self.pkcs8(der), kind: "PRIVATE KEY")) == der)
        let jwt = try GitHubAppKey.jwt(appID: "7", pem: Self.pem(Self.pkcs8(der), kind: "PRIVATE KEY"))
        #expect(try Self.verified(jwt, by: key))
        #expect(throws: GitHubAppKey.Failure.key) { try GitHubAppKey.jwt(appID: "7", pem: "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----") }
        #expect(throws: GitHubAppKey.Failure.key) { try GitHubAppKey.jwt(appID: "7", pem: "not a key") }
        #expect(GitHubAppKey.pkcs1(pkcs8: Data([0x30, 0x03, 0x02, 0x01, 0x01])) == nil)
    }

    @Test func eachOwnersKeyHasItsOwnVariableName() {
        #expect(GitHubAppKey.variable(owner: "One-Org") == "GITHUB_APP_ONE_ORG_KEY")
        let long = GitHubAppKey.variable(owner: String(repeating: "a", count: 39))
        #expect(LoginSecret.isVariable(long) && long.count <= 60 && long.hasSuffix("_KEY") && !LoginSecret.isReserved(long))
    }
}
