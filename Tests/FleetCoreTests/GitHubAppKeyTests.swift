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

    private static func key(_ name: String) -> TeamLogin { TeamLogin(title: name, protected: true, kind: "api_key", env: name) }
    private static let old = "bws://00000001-0000-4000-8000-000000000000"
    private static let second = "bws://00000002-0000-4000-8000-000000000000"
    private static let other = "bws://00000003-0000-4000-8000-000000000000"

    /// The owner's case of 20 November 2026: the list had the key of his App, he saved the App's new key, and the hub
    /// refused it, because the app gave it the name of the old one and the list takes no second key of one name. The
    /// new key gets a name that no key of the list has, which the hub takes as a key's name, so the two stand side by
    /// side: the door needs the old one to show that GitHub refuses it.
    @Test func theSuccessorOfAnAppsKeyGetsANameThatNoKeyOfTheListHas() async {
        #expect(await GitHubAppKey.place(owner: "acme", catalog: [:]) { _ in true } == .new(variable: "GITHUB_APP_ACME_KEY"))
        // a login with that title and a key of another name are no keys of this owner: the hub is not asked about them
        var catalog = [Self.old: Self.key("GITHUB_APP_ACME_KEY"), Self.other: Self.key("OPENAI_API_KEY"),
                       "bws://00000004-0000-4000-8000-000000000000": TeamLogin(title: "GITHUB_APP_ACME_2_KEY", protected: true)]
        #expect(await GitHubAppKey.place(owner: "Acme", catalog: catalog) { $0 != Self.old } == .new(variable: "GITHUB_APP_ACME_2_KEY"))
        // a hub that cannot tell whether an entry is this key: a new entry, never the place of a key that works
        #expect(await GitHubAppKey.place(owner: "Acme", catalog: catalog) { _ in nil } == .new(variable: "GITHUB_APP_ACME_2_KEY"))
        catalog[Self.second] = Self.key("GITHUB_APP_ACME_2_KEY")
        #expect(await GitHubAppKey.place(owner: "Acme", catalog: catalog) { _ in false } == .new(variable: "GITHUB_APP_ACME_3_KEY"))
        catalog[Self.old] = nil         // the old key left the list: its name is free again
        #expect(await GitHubAppKey.place(owner: "Acme", catalog: catalog) { _ in false } == .new(variable: "GITHUB_APP_ACME_KEY"))
        for number in [2, 10, 257] {
            let name = GitHubAppKey.variable(owner: String(repeating: "a", count: 39), number: number)
            #expect(LoginSecret.isVariable(name) && name.count <= 60 && name.hasSuffix("_\(number)_KEY") && !LoginSecret.isReserved(name))
        }
    }

    /// A save that failed after its hub step, and the same file a second time: the list has an entry of this very key,
    /// and the save goes to that entry again. A new entry for it made 49 entries of one name on 6 November 2026, and
    /// since 13 November the hub refuses it.
    @Test func aKeyThatTheListHoldsGoesToItsOwnEntryAgain() async {
        let catalog = [Self.old: Self.key("GITHUB_APP_ACME_KEY"), Self.second: Self.key("GITHUB_APP_ACME_2_KEY")]
        #expect(await GitHubAppKey.place(owner: "acme", catalog: catalog) { $0 == Self.old }
                == .held(reference: Self.old, variable: "GITHUB_APP_ACME_KEY"))
        #expect(await GitHubAppKey.place(owner: "acme", catalog: catalog) { $0 == Self.second }
                == .held(reference: Self.second, variable: "GITHUB_APP_ACME_2_KEY"))
        // the reference that an earlier try of this key kept is the key's own entry, with no question to the hub
        #expect(await GitHubAppKey.place(owner: "acme", catalog: catalog, kept: Self.second) { _ in false }
                == .held(reference: Self.second, variable: "GITHUB_APP_ACME_2_KEY"))
        // a kept reference that the list does not have yet decides nothing
        #expect(await GitHubAppKey.place(owner: "acme", catalog: catalog, kept: Self.other) { _ in false }
                == .new(variable: "GITHUB_APP_ACME_3_KEY"))
        // a question that fails is no "not this key": the search ends with its error, and no third entry is made
        await #expect(throws: HubError.self) {
            try await GitHubAppKey.place(owner: "acme", catalog: catalog) { _ in throw HubError.invalidResponse }
        }
    }
}
