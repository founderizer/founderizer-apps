import Foundation
import Testing
@testable import FleetStoreKeys

/// **The SDK's own vectors** (bitwarden/sdk-internal: `shareable_key.rs`, `access_token.rs`,
/// `aes256_cbc_hmac_sha256_ae.rs`; bitwarden/sdk-sm: the fake server's sign-in and items). None of them was made with
/// this code. The bug that they catch: items that the operator cannot read, or a sign-in whose payload never opens.
struct BitwardenCryptoTests {
    @Test func theSharedKeyDerivationIsTheSDKs() {
        let first = ShareableKey.derive(Data("&/$%F1a895g67HlX".utf8), name: "test_key", info: nil)!
        #expect(first.bytes.base64EncodedString()
                == "4PV6+PcmF2w7YHRatvyMcVQtI7zvCyssv/wFWmzjiH6Iv9altjmDkuBD1aagLVaLezbthbSe+ktR+U6qswxNnQ==")
        let second = ShareableKey.derive(Data("67t9b5g67$%Dh89n".utf8), name: "test_key", info: "test")!
        #expect(second.bytes.base64EncodedString()
                == "F9jVQmrACGx9VUPjuzfMYDjr726JtL300Y3Yg+VYUnVQtQ1s8oImJ5xtp1KALC9h2nav04++1LDW4iFD+infng==")
    }

    @Test func theAccessTokenOpensTheSDKsPayloadAndItsKeyOpensAnItem() throws {
        let token = try #require(BitwardenAccessToken(
            "0.ec2c1d46-6a4b-4751-a310-af9601317f2d.C2IgxjjLF7qSshsbwe8JGcbM075YXw:X8vbvA0bduihIDe/qrzIQQ=="))
        #expect(token.id == "ec2c1d46-6a4b-4751-a310-af9601317f2d")
        #expect(token.clientSecret == "C2IgxjjLF7qSshsbwe8JGcbM075YXw")
        #expect(token.key.bytes.base64EncodedString()
                == "H9/oIRLtL9nGCQOVDjSMoEbJsjWXSOCb3qeyDt6ckzS3FhyboEDWyTP/CQfbIszNmAVg2ExFganG1FVFGXO/Jg==")
        // The fake server's sign-in: its payload, opened with that token's key, gives the organization key.
        let payload = "2.E9fE8+M/VWMfhhim1KlCbQ==|eLsHR484S/tJbIkM6spnG/HP65tj9A6Tba7kAAvUp+rYuQmGLixiOCfMsqt5OvBctDfvvr/Aes"
            + "Bu7cZimPLyOEhqEAjn52jF0eaI38XZfeOG2VJl0LOf60Wkfh3ryAMvfvLj3G4ZCNYU8sNgoC2+IQ==|lNApuCQ4Pyakfo/wwuuajWNaEX/2MW8/3rjXB/V7n+k="
        let key = try #require(SignInParts.organizationKey(payload: payload, token: token))
        #expect(key.bytes.base64EncodedString()
                == "k/6PcwG7Hm/eZfvvOvP6EqGx1JKgbzYrWwpOIHsxbJHQMpIMg5Ud94AQHduSR+XMMaFiSB+nszbO4JPXj04YwA==")
        // The fake server's items, as that organization key opens them.
        #expect(EncString.openText("2.pMS6/icTQABtulw52pq2lg==|XXbxKxDTh+mWiN1HjH2N1w==|Q6PkuT+KX/axrgN9ubD5Ajk2YNwxQkgs3WJM0S0wtG8=",
                                   key: key) == "TEST")
        #expect(EncString.openText("2.OldQj0RJKww0WN7RSxI1wQ==|TpxAbmdx6zIVo37YJ5n1aQ==|06Imyx7jqaZ5J5amrBboCVPwvPoDKB8REJdToQwp3dA=",
                                   key: key) == "TUX")
        // Its JWT names the organization by the claim that the SDK reads.
        let jwt = "eyJhbGciOiJSUzI1NiJ9.eyJuYmYiOjE2NzUxMDM3ODEsImV4cCI6MTY3NTEwNzM4MSwiaXNzIjoiaHR0cDovL2xvY2FsaG9zdCIsImNsaWVudF9pZCI6ImVjMmMxZDQ2LTZhNGItNDc1MS1hMzEwLWFmOTYwMTMxN2YyZCIsInN1YiI6ImQzNDgwNGNhLTRmNmMtNDM5Mi04NmI3LWFmOTYwMTMxNzVkMCIsIm9yZ2FuaXphdGlvbiI6ImY0ZTQ0YTdmLTExOTAtNDMyYS05ZDRhLWFmOTYwMTMxMjdjYiIsImp0aSI6IjU3QUU0NzQ0MzIwNzk1RThGQkQ4MUIxNDA2RDQyNTQyIiwiaWF0IjoxNjc1MTAzNzgxLCJzY29wZSI6WyJhcGkuc2VjcmV0cyJdfQ.c2ln"
        #expect(SignInParts.organization(ofJWT: jwt) == "f4e44a7f-1190-432a-9d4a-af96013127cb")
    }

    @Test func typeTwoEncryptionIsTheSDKs() throws {
        let key = try #require(CompositeKey(Data(0..<64)))
        let iv = Data([216, 218, 36, 0, 196, 186, 150, 85, 49, 147, 110, 168, 185, 227, 42, 172])
        let data = Data([234, 77, 16, 15, 189, 82, 36, 188, 182, 88, 64, 67, 145, 94, 30, 178, 36, 235, 130, 67, 255, 207,
                         183, 168, 73, 231, 82, 122, 193, 139, 25, 129])
        let mac = Data([60, 78, 44, 111, 72, 233, 3, 6, 86, 250, 217, 242, 62, 229, 184, 221, 231, 150, 189, 44, 99, 189,
                        220, 55, 196, 194, 101, 60, 102, 195, 149, 130])
        let vector = "2." + [iv, data, mac].map { $0.base64EncodedString() }.joined(separator: "|")
        #expect(try EncString.open(vector, key: key) == Data("Bitwarden SDK test vector".utf8))
        // The same IV and key seal the SDK's own text, so what this Mac writes is what the SDK reads.
        #expect(try EncString.seal(Data("Bitwarden SDK test vector".utf8), key: key, iv: iv) == vector)
        let fixed = Data([62, 0, 239, 47, 137, 95, 64, 214, 127, 91, 184, 232, 31, 9, 165, 161])
        let sealed = try EncString.seal(Data("EncryptMe!".utf8), key: key, iv: fixed)
        #expect(Data(base64Encoded: String(sealed.split(separator: "|")[1]))
                == Data([214, 76, 187, 97, 58, 146, 212, 140, 95, 164, 177, 204, 179, 133, 172, 148]))
        // A changed MAC opens nothing.
        var broken = mac
        broken[0] &+= 1
        let tampered = "2." + [iv, data, broken].map { $0.base64EncodedString() }.joined(separator: "|")
        #expect(throws: EncString.Failure.integrity) { try EncString.open(tampered, key: key) }
    }

    /// The SDK's own malformed tokens: the bug is a token that the form keeps and that no sign-in takes.
    @Test func onlyTheSDKsTokenFormIsAToken() {
        let good = "0.ec2c1d46-6a4b-4751-a310-af9601317f2d.C2IgxjjLF7qSshsbwe8JGcbM075YXw:X8vbvA0bduihIDe/qrzIQQ=="
        #expect(BitwardenAccessToken(good) != nil)
        #expect(BitwardenAccessToken(String(good.dropLast(2))) != nil)            // the SDK takes no padding too
        #expect(BitwardenAccessToken("1" + good.dropFirst()) == nil)               // another version
        #expect(BitwardenAccessToken(good.replacingOccurrences(of: ":", with: ".")) == nil)
        #expect(BitwardenAccessToken(String(good.dropFirst(2))) == nil)           // two parts
        #expect(BitwardenAccessToken(String(good.prefix(while: { $0 != ":" }))) == nil)   // no key
        #expect(BitwardenAccessToken(good.replacingOccurrences(of: "X8vbvA0bduihIDe/qrzIQQ==", with: "X8vbvA0bduihIDe/qrzI")) == nil)
    }
}
