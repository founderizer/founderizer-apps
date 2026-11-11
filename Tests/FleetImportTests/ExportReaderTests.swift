import Foundation
import Testing
@testable import FleetImport

private func data(_ text: String) -> Data { Data(text.utf8) }

struct ExportReaderTests {
    @Test func aPlainBitwardenExportGivesLoginsAndKeys() throws {
        let reading = try ExportReader.bitwarden(data(Fixtures.bitwardenPlain))
        #expect(reading.source == .bitwarden)
        #expect(reading.found.count == 5)
        let shop = try #require(reading.found[0].candidate)
        #expect(shop == Candidate(kind: .login, url: "https://shop.example.test/login", username: "owner@example.test",
                                  password: "synthetic-pass-phrase-1",
                                  totp: "otpauth://totp/Shop:owner?secret=JBSWY3DPEHPK3PXP&issuer=Shop"))
        #expect(reading.found[1].candidate == Candidate(kind: .apiKey, password: "sk_test_synthetic_000111", env: "STRIPE_LIVE_KEY"))
        #expect(reading.found[2].skipped == .note && reading.found[3].skipped == .card && reading.found[4].skipped == .noValue)
        #expect(reading.found.map(\.name) == ["Shop admin", "Stripe live key", "Wi-Fi notes", "Company card", "No password here"])
    }

    @Test func aPasswordProtectedExportOpensWithItsPasswordOnly() throws {
        for file in [Fixtures.bitwardenPBKDF2, Fixtures.bitwardenArgon2] {
            #expect(throws: ExportReader.Failure.password(wrong: false)) { try ExportReader.bitwarden(data(file)) }
            #expect(throws: ExportReader.Failure.password(wrong: false)) { try ExportReader.bitwarden(data(file), password: " \n") }
            #expect(throws: ExportReader.Failure.password(wrong: true)) { try ExportReader.bitwarden(data(file), password: "wrong one") }
            let reading = try ExportReader.bitwarden(data(file), password: "export pass synthetic")
            #expect(reading.found == (try ExportReader.bitwarden(data(Fixtures.bitwardenPlain))).found)
        }
    }

    @Test func anAccountLockedExportIsNamedAsSuch() {
        #expect(throws: ExportReader.Failure.lockedToAccount) { try ExportReader.bitwarden(data(Fixtures.bitwardenAccount)) }
    }

    @Test func aChangedByteOfALockedExportIsNotOpened() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: data(Fixtures.bitwardenPBKDF2)) as? [String: Any])
        var sealed = try #require(object["data"] as? String)
        let index = sealed.index(sealed.startIndex, offsetBy: 30)
        sealed.replaceSubrange(index ... index, with: sealed[index] == "A" ? "B" : "A")
        object["data"] = sealed
        let changed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: ExportReader.Failure.damaged) { try ExportReader.bitwarden(changed, password: "export pass synthetic") }
    }

    @Test func aSecretsManagerExportGivesAPIKeys() throws {
        let reading = try ExportReader.bitwarden(data(Fixtures.secretsManager))
        #expect(reading.source == .bitwardenSecrets)
        #expect(reading.found[0].candidate == Candidate(kind: .apiKey, password: "sk-synthetic-0000001", env: "OPENAI_API_KEY"))
        #expect(reading.found[1].skipped == .noValue)
    }

    @Test func aOnePasswordExportGivesItsItems() throws {
        let file = try #require(Data(base64Encoded: Fixtures.onePassword1PUX))
        let reading = try ExportReader.onePassword(file)
        #expect(reading.source == .onePassword)
        #expect(reading.found.map(\.name) == ["GitHub", "Mailgun key", "Twilio API", "Old login", "A note"])
        #expect(reading.found[0].candidate == Candidate(kind: .login, url: "https://github.example.test/login", username: "octo-synthetic",
                                                        password: "synthetic-github-pass", totp: "JBSWY3DPEHPK3PXP"))
        #expect(reading.found[1].candidate == Candidate(kind: .apiKey, password: "key-synthetic-123456", env: "MAILGUN_KEY"))
        #expect(reading.found[2].candidate == Candidate(kind: .apiKey, url: "https://api.twilio.example.test",
                                                        password: "tw-synthetic-credential", env: "TWILIO_API_KEY"))
        #expect(reading.found[3].skipped == .archived && reading.found[4].skipped == .note)
    }

    @Test func aOnePasswordCSVGivesItsRows() throws {
        let reading = try ExportReader.onePasswordCSV(data(Fixtures.onePasswordCSV))
        #expect(reading.found.count == 3)
        #expect(reading.found[0].name == "Bank, main")
        #expect(reading.found[0].candidate == Candidate(kind: .login, url: "https://bank.example.test", username: "me@example.test",
                                                        password: "pa\"ss-synthetic-9"))
        #expect(reading.found[1].candidate == Candidate(kind: .apiKey, password: "tok-synthetic-55555", env: "API_TOKEN"))
        #expect(reading.found[2].skipped == .archived)
    }

    @Test func otherFilesAreNotExports() {
        #expect(throws: ExportReader.Failure.notAnExport) { try ExportReader.bitwarden(data("{\"a\": 1}")) }
        #expect(throws: ExportReader.Failure.notAnExport) { try ExportReader.bitwarden(data("not json")) }
        #expect(throws: ExportReader.Failure.damaged) { try ExportReader.onePassword(data("PK not a zip at all, but long enough")) }
        #expect(throws: ExportReader.Failure.notAnExport) { try ExportReader.onePasswordCSV(data("a,b\n1,2\n")) }
    }

    @Test func variableNamesFollowTheHubsRule() {
        // The hub's rule, `lifecycle.key_env`: A-Z 0-9 _, a letter first, an ending of a key, 60 characters at most.
        #expect(ExportReader.variable("Stripe live key") == "STRIPE_LIVE_KEY")
        #expect(ExportReader.variable("Twilio API") == "TWILIO_API_KEY")
        #expect(ExportReader.variable("Acme PIA token") == "ACME_PIA_TOKEN")
        #expect(ExportReader.variable("deploy_secret") == "DEPLOY_SECRET")
        #expect(ExportReader.variable("DB password") == "DB_PASSWORD")
        #expect(ExportReader.variable("github pat") == "GITHUB_PAT")
        #expect(ExportReader.variable("2fa backup") == "KEY_2FA_BACKUP_KEY")
        #expect(ExportReader.variable("  Über-Größe (prod) ") == "UBER_GROSSE_PROD_KEY")
        #expect(ExportReader.variable("***") == "")
        let long = ExportReader.variable(String(repeating: "a", count: 80))
        #expect(long.count == 60 && long.hasSuffix("_KEY"))
        #expect(ExportReader.variable(String(repeating: "b", count: 56) + "_TOKEN").count == 60)
        #expect(ExportReader.variable(String(repeating: "b", count: 57) + "_TOKEN").hasSuffix("_KEY"))
    }

    @Test func aLoginNeedsAWebAddress() throws {
        #expect(ExportReader.webAddress("https://shop.example.test/login") == "https://shop.example.test/login")
        #expect(ExportReader.webAddress("shop.example.test/login") == "https://shop.example.test/login")
        #expect(ExportReader.webAddress("androidapp://com.example") == nil)
        #expect(ExportReader.webAddress("localhost") == nil)
        #expect(ExportReader.webAddress("not a host.com") == nil)
        #expect(ExportReader.webAddress("user@host.com") == nil)
        let items = #"{"encrypted":false,"folders":[],"items":[{"type":1,"name":"No page","login":{"username":"me","password":"synthetic-pass-1","uris":[{"uri":"iosapp://x"}]}},{"type":1,"name":"Bare host","login":{"username":"me","password":"synthetic-pass-2","uris":[{"uri":"example.test"}]}}]}"#
        let reading = try ExportReader.bitwarden(data(items))
        #expect(reading.found[0].skipped == .noAddress && reading.found[0].candidate == nil)
        #expect(reading.found[1].candidate?.url == "https://example.test" && reading.found[1].candidate?.kind == .login)
    }

    @Test func aSecretsManagerItemThatHoldsALoginAsJSONIsALogin() throws {
        let file = #"{"projects":[],"secrets":[{"key":"site-a","value":"{\"username\":\"me@example.test\",\"password\":\"synthetic-pass-9\",\"url\":\"https://site.example.test/login\",\"totp\":\"JBSWY3DPEHPK3PXP\"}"},{"key":"plain_token","value":"tok-synthetic-77777"},{"key":"half","value":"{\"password\":\"synthetic-pass-8\"}"}]}"#
        let reading = try ExportReader.bitwarden(data(file))
        #expect(reading.found[0].candidate == Candidate(kind: .login, url: "https://site.example.test/login", username: "me@example.test",
                                                        password: "synthetic-pass-9", totp: "JBSWY3DPEHPK3PXP"))
        #expect(reading.found[1].candidate == Candidate(kind: .apiKey, password: "tok-synthetic-77777", env: "PLAIN_TOKEN"))
        #expect(reading.found[2].candidate?.kind == .apiKey)            // a JSON that is no login stays the key itself
    }

    @Test func aValueThatBitwardenCouldNotDecryptIsNotImported() throws {
        let file = #"{"projects":[],"secrets":[{"key":"A_KEY","value":"[error: cannot decrypt]"}]}"#
        #expect(try ExportReader.bitwarden(data(file)).found[0].skipped == .unreadable)
    }
}
