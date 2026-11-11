import FleetCore
import Foundation
import Testing
@testable import FleetImport

/// Synthetic export files only (`Fixtures`, made by `make_fixtures.py` with another implementation of the formats):
/// no test names a real login. Each test makes its own folder and removes it.
struct SecretImportTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ data: Data, named name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func aBitwardenFileGivesRowsThatAddSecretWouldSave() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try file(Data(Fixtures.bitwardenPlain.utf8), named: "bitwarden.json", in: directory)
        let reading = try SecretImport.read(url, vendor: .bitwarden)
        #expect(reading.rows.map(\.secret.title) == ["shop.example.test · owner@example.test", "STRIPE_LIVE_KEY"])
        #expect(reading.rows.allSatisfy { $0.problem == nil })
        #expect(reading.rows[0].secret.kind == .login && reading.rows[1].secret.kind == .apiKey)
        #expect(reading.skippedLine == "Not imported: 1 note, 1 card and 1 item with no password.")
        // The value that a save seals is the one that every vault reads.
        let value = try #require(try JSONSerialization.jsonObject(with: reading.rows[0].secret.value()) as? [String: String])
        #expect(value == ["username": "owner@example.test", "password": "synthetic-pass-phrase-1",
                          "url": "https://shop.example.test/login", "totp": "otpauth://totp/Shop:owner?secret=JBSWY3DPEHPK3PXP&issuer=Shop"])
        let key = try #require(try JSONSerialization.jsonObject(with: reading.rows[1].secret.value()) as? [String: String])
        #expect(key == ["username": "", "password": "sk_test_synthetic_000111"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["bitwarden.json"])      // it made no file
    }

    @Test func aLockedFileNeedsItsPassword() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, text) in [("pbkdf2.json", Fixtures.bitwardenPBKDF2), ("argon2.json", Fixtures.bitwardenArgon2)] {
            let url = try file(Data(text.utf8), named: name, in: directory)
            #expect(throws: SecretImport.Failure.password(wrong: false)) { try SecretImport.read(url, vendor: .bitwarden) }
            #expect(throws: SecretImport.Failure.password(wrong: true)) { try SecretImport.read(url, vendor: .bitwarden, password: "no") }
            #expect(try SecretImport.read(url, vendor: .bitwarden, password: "export pass synthetic").rows.count == 2)
        }
    }

    @Test func aFileThatOnlyTheAccountOpensIsNamedAsSuch() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try file(Data(Fixtures.bitwardenAccount.utf8), named: "account.json", in: directory)
        #expect(throws: SecretImport.Failure.lockedToAccount) { try SecretImport.read(url, vendor: .bitwarden) }
        #expect(SecretImport.Failure.lockedToAccount.errorDescription?.hasPrefix("Only your Bitwarden account") == true)
    }

    @Test func aSecretsManagerFileGivesAPIKeys() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try file(Data(Fixtures.secretsManager.utf8), named: "secrets.json", in: directory)
        let reading = try SecretImport.read(url, vendor: .bitwarden)
        #expect(reading.rows.map(\.secret.title) == ["OPENAI_API_KEY"])
        #expect(reading.skippedLine == "Not imported: 1 item with no password.")
    }

    @Test func aOnePasswordFileIsReadByItsContentNotItsName() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let zip = try file(try #require(Data(base64Encoded: Fixtures.onePassword1PUX)), named: "export.csv", in: directory)
        let csv = try file(Data(Fixtures.onePasswordCSV.utf8), named: "export.1pux", in: directory)
        let archive = try SecretImport.read(zip, vendor: .onePassword)
        #expect(archive.rows.map(\.secret.title) == ["github.example.test · octo-synthetic", "MAILGUN_KEY", "TWILIO_API_KEY"])
        #expect(archive.skippedLine == "Not imported: 1 note and 1 archived item.")
        let table = try SecretImport.read(csv, vendor: .onePassword)
        #expect(table.rows.map(\.secret.title) == ["bank.example.test · me@example.test", "API_TOKEN"])
        #expect(table.skippedLine == "Not imported: 1 archived item.")
    }

    @Test func theWrongVendorsFileIsNamedAsSuch() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try file(Data(Fixtures.onePasswordCSV.utf8), named: "export.csv", in: directory)
        #expect(throws: SecretImport.Failure.notAnExport(.bitwarden)) { try SecretImport.read(url, vendor: .bitwarden) }
        let empty = try file(Data(), named: "empty.1pux", in: directory)
        #expect(throws: SecretImport.Failure.notAnExport(.onePassword)) { try SecretImport.read(empty, vendor: .onePassword) }
        #expect(throws: SecretImport.Failure.unreadable) { try SecretImport.read(directory.appendingPathComponent("none.json"), vendor: .bitwarden) }
    }

    @Test func aRowThatTheVaultsCannotReadSaysWhy() {
        var secret = LoginSecret()
        secret.kind = .apiKey; secret.env = "PATH"; secret.password = "synthetic-value-1"
        #expect(SecretImport.Row(id: 0, secret: secret).problem == "PATH is a name that a session sets itself. Give another name.")
        secret.env = "ANTHROPIC_API_KEY"
        #expect(SecretImport.Row(id: 0, secret: secret).problem == "ANTHROPIC_API_KEY is a name that a session sets itself. Give another name.")
        secret.env = "SYNTHETIC_API_KEY"
        #expect(SecretImport.Row(id: 0, secret: secret).problem == nil)
    }
}
