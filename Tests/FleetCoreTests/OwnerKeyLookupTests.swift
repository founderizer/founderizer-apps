import CryptoKit
import Foundation
import Security
import Testing
@testable import FleetCore

/// **A read of the owner key that fails now never leads to a new owner key** (two Opus readers of the Windows owner
/// key, 24 November 2026). The bugs that this catches: one passing error of the keychain (a locked keychain, a refusal)
/// or of the enclave (it refuses its own wrapped key for a moment) made the key nil, and the central vault's install
/// then made a new owner key over the old one, a new identity for the hub with no word to the owner, whose pins the
/// Linux brokers refuse; an enclave that refused a new key once gave a software key on a Mac that has an enclave.
struct OwnerKeyLookupTests {
    private static func soft(_ data: Data) -> (any OwnerKey)? {
        (try? P256.Signing.PrivateKey(rawRepresentation: data)).map { SoftwareOwnerKey($0) }
    }

    private static func failed(_ status: OSStatus) -> Result<Data, FleetKeychainItem.Failure> {
        .failure(FleetKeychainItem.Failure(label: "owner key", status: status))
    }

    @Test func onlyAnItemThatIsNotThereIsNone() {
        guard case .none = OwnerKeychain.lookup(Self.failed(errSecItemNotFound), open: Self.soft) else {
            Issue.record("an item that is not there is none")
            return
        }
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable, errSecDecode] {
            guard case .notNow(let failure) = OwnerKeychain.lookup(Self.failed(status), open: Self.soft),
                  failure.status == status else {
                Issue.record("the keychain's status \(status) is a read that failed now, never none")
                return
            }
        }
        let raw = P256.Signing.PrivateKey().rawRepresentation
        guard case .key = OwnerKeychain.lookup(.success(raw), open: Self.soft) else {
            Issue.record("a key that opens is the key")
            return
        }
        // Data that no key opens now (the enclave refused its own wrapped form) is not none either.
        guard case .notNow = OwnerKeychain.lookup(.success(Data(repeating: 7, count: 300)), open: Self.soft) else {
            Issue.record("held data that does not open is not none")
            return
        }
    }

    /// The one place that makes an owner key makes it only on `none`; the bug: a later change puts back
    /// `OwnerKeychain.key(fleet:) ?? OwnerKeychain.make(fleet:)`, whose nil is also a read that failed now.
    @Test func theInstallMakesAKeyOnlyOnNone() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        var makers: [String] = []
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("OwnerKeychain.make(") {
                makers.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(makers == ["CentralVaultSection.swift: case .none: key = try OwnerKeychain.make(fleet: fleet)"], "\(makers)")
    }

    /// **The same rule for the recovery code and the owner access key** (the Door area's read of 24 November 2026), whose
    /// `kept` the vault's recovery step and the sweep call: only "not there" lets a new value in. Bugs: one failed read
    /// made a new recovery code, so the backups sealed to the old one could no longer be opened; or a new owner access
    /// key, while the fleet's copies keep the old one; or `make`'s own guard lets a value in over held data.
    @Test func aNewValueOnlyWhereTheItemIsNotThere() throws {
        let item = FleetKeychainItem(service: "com.example.test", label: "recovery code")
        try item.mayMake(Self.failed(errSecItemNotFound))
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecMissingEntitlement, errSecUserCanceled] {
            #expect(throws: FleetKeychainItem.Failure.self, "status \(status)") { try item.mayMake(Self.failed(status)) }
        }
        #expect(throws: FleetKeychainItem.Failure.self, "held data") { try item.mayMake(.success(Data([1]))) }
        let code = try RecoveryCode.make()
        guard case .value(let back) = item.held(.success(Data(code.normalized.utf8)), decode: RecoveryKeychain.decode),
              back == code else {
            Issue.record("a kept code reads back")
            return
        }
        guard case .notNow = item.held(Self.failed(errSecInteractionNotAllowed), decode: RecoveryKeychain.decode),
              case .notNow = item.held(.success(Data("not a code".utf8)), decode: RecoveryKeychain.decode),
              case .none = item.held(Self.failed(errSecItemNotFound), decode: { OwnerAccessKey(seed: $0) }) else {
            Issue.record("a read that failed now, or data that does not read, is never none")
            return
        }
        // Both `kept` go through that rule: a later change that puts back `if let … = key(fleet:)` fails here.
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FleetCore")
        for file in ["RecoveryCode.swift", "OwnerAccessKey.swift"] {
            let text = try String(contentsOf: core.appendingPathComponent(file), encoding: .utf8)
            let start = try #require(text.range(of: "public static func kept(fleet: String) throws"), "\(file)")
            let end = try #require(text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex), "\(file)")
            let body = text[start.upperBound..<end.lowerBound]
            // the keychain's answer comes first, and no read whose nil is also a failure comes before it
            let first = body.split(separator: "\n").dropFirst().first?.trimmingCharacters(in: .whitespaces)
            #expect(first == "let read = item.lookup(fleet: fleet)", "\(file): \(first ?? "")")
            #expect(body.contains("item.held(read") && body.contains("case .none: try item.mayMake(read)"), "\(file)")
        }
    }

    @Test func aSoftwareKeyOnlyOnAMacWithNoEnclave() throws {
        struct Refused: Error {}
        #expect(throws: Refused.self) { _ = try OwnerKeychain.new(enclave: true) { throw Refused() } }
        let made = try OwnerKeychain.new(enclave: false) { throw Refused() }
        #expect(made.0 is SoftwareOwnerKey && made.1.count == 32)
    }
}
