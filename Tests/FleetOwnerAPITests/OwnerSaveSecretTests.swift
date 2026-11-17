import Foundation
import Testing
@testable import FleetCore
@testable import FleetOwnerAPI

/// A made-up value in the form that `save_secret` takes: of no service. Its two parts are put together here, so that
/// no file holds something with a key's shape as one literal (a scanner of a public repository reads such a literal
/// as a real key).
let exampleSecretValue = "example-" + "value-0123"

/// What the tests of `save_secret` share: example fields, and the words of a refusal.
enum SaveSecretSample {
    static let id = "11111111-2222-4333-8444-555555555555"
    static let reference = "bws://aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    static let key: [String: JSONValue] = ["kind": .string("api_key"), "env": .string("EXAMPLE_API_KEY"),
                                           "from": .string("clipboard")]
    static let login: [String: JSONValue] = ["kind": .string("login"), "url": .string("https://shop.example.com/login"),
                                             "username": .string("owner@example.com"), "from": .string("clipboard")]

    static func with(_ base: [String: JSONValue], _ more: [String: JSONValue]) -> [String: JSONValue] {
        base.merging(more) { $1 }
    }

    /// The refusal of the fields' read in the program, or nil for fields that it takes.
    static func refusal(_ fields: [String: JSONValue], app: Bool = false) -> String? {
        if case .failure(let refusal) = SaveSecret.read(fields, app: app) { return refusal.text }
        return nil
    }

    /// The refusal of the program's plan, or nil for a call that it takes.
    static func planRefusal(_ fields: [String: JSONValue], standardInputFree: Bool = true) -> String? {
        if case .failure(let refusal) = SaveSecret.plan(fields, standardInputFree: standardInputFree) { return refusal.text }
        return nil
    }
}

/// **The forms of `save_secret`'s fields and of its value, and its two lists** (the secrets plan, step E1). The lists
/// are held to the hub's and the vault's own files where this repository has them: the public copy of the apps has no
/// root Python file.
struct OwnerSaveSecretFormTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let lifecycle = root.appendingPathComponent("lifecycle.py")
    static let vault = root.appendingPathComponent("vault.py")

    static let goodNames: [String] = ["EXAMPLE_API_KEY", "A_KEY", "X1_TOKEN", "EXAMPLE_SECRET", "EXAMPLE_PASSWORD", "EXAMPLE_PAT",
                            "FLEETS_API_KEY", "MY_ANTHROPIC_API_KEY", "E" + String(repeating: "X", count: 55) + "_KEY"]
    static let badNames: [String] = ["", "example_api_key", "Example_API_KEY", "1EXAMPLE_KEY", "_EXAMPLE_KEY", "EXAMPLE",
                           "EXAMPLE_KEYS", "KEY", "EXAMPLE-API_KEY", "EXAMPLE API_KEY", " EXAMPLE_API_KEY",
                           "EXAMPLE_API_KEY ", "EXAMPLE_API_KEY\n", "EXAMPLE_API_KEY\r\n", "EXAMPLE_API_KEY\r",
                           "EXAMPLE_API_KEY\u{2028}", "EXAMPLE_API_KEY\u{0}", "\u{FEFF}EXAMPLE_API_KEY",
                           "E" + String(repeating: "X", count: 56) + "_KEY",
                           "\u{415}XAMPLE_API_KEY",            // a Cyrillic letter that looks like E
                           "\u{FF25}XAMPLE_API_KEY",           // a full-width E
                           "EXAMPLE_API_KE\u{212A}",           // the Kelvin sign for the K
                           "EXAMPLE\u{661}_KEY",               // an Arabic-Indic digit
                           "FLEET_EXAMPLE_KEY", "BWS_ACCESS_TOKEN", "LD_EXAMPLE_KEY", "DYLD_EXAMPLE_KEY",
                           "ANTHROPIC_API_KEY", "CLAUDE_EXAMPLE_TOKEN", "CODEX_EXAMPLE_KEY", "XAI_API_KEY"]

    /// A host of 194 characters in labels that a name server takes, and an address of exactly 300 with it.
    static let longHost = String(repeating: String(repeating: "a", count: 60) + ".", count: 3) + "example.com"
    static let longSite = "https://" + longHost + "/" + String(repeating: "p", count: 300 - 8 - longHost.count - 1)

    static let goodSites: [String] = ["https://example.com", "http://example.com", "https://api.example.com/v1",
                            "https://example.com:8443/a/b?c=d&e=f", "https://203.0.113.7:8080/", "https://a",
                            "https://example.com/", "https://example.com:0", "https://example.com/A%20b/~c;d=e,f",
                            "https://example.com/%41", "https://example.com/a%2Fb?c=%20d&e=%7e",
                            "https://example.com/%e2%82%ac", "https://example.com/a%41",
                            "https://xn--bcher-kva.example.com/", "https://a.b-c.example.com:65535/x?y=(z)&w=@me",
                            "https://example.com/claude.ai", "https://example.com/?next=https://claude.ai/login",
                            "https://notclaude.ai/", "https://claude.ai.example.com/", "https://openai.com/",
                            "https://platform.openai.com/api-keys", "https://api.openai.com/v1",
                            "https://platform.claude.com/settings/keys", "https://eu.platform.claude.com/",
                            "https://api.x.ai/v1", "https://example.com:99999", longSite]
    static let badSites: [String] = ["", "example.com", "ftp://example.com", "HTTPS://example.com", "Https://example.com",
                           "https://Example.com", "https://example.com/ path", "https://example.com\n",
                           "https://example.com/\n", "https://example.com\r\n", "https://example.com/path\r",
                           "https://example.com\u{2028}", " https://example.com", "https://example.com ",
                           "https://owner@example.com", "https://owner@example.com/", "https://example.com:80@example.org/",
                           "https://example.com#top", "https://example.com/a#top", "https://example.com?x=1",
                           "https://-example.com", "https://example.com-", "https://example.com.", "https://.example.com",
                           "https://example.com:", "https://example.com:/", "https://example.com:123456",
                           "https://example.com:8a", "https://ex\u{E4}mple.com", "https://example.com/\u{E4}",
                           "https://example.com:\u{668}\u{660}", "https://[2001:db8::1]/", "https://example.com/a\\b",
                           "https://example.com/a\"b", "https://example.com/<a>", "https://", "https:///path",
                           "https:/example.com", "https://example_com", "https://example.com/a\tb", longSite + "p",
                           // A "%" with no two hex digits after it.
                           "https://example.com/%", "https://example.com/a%", "https://example.com/a%4",
                           "https://example.com/a%zz", "https://example.com/a%4g", "https://example.com/a%g4",
                           "https://example.com/%%41", "https://example.com/%4/1", "https://example.com/a?b=%",
                           "https://example.com/a?b=%2", "https://example.com:8443/%2?", "https://example.com/%41%",
                           // The model providers' own sign-in sites, with the names under them.
                           "https://claude.ai", "https://claude.ai/login", "http://claude.ai", "https://www.claude.ai/",
                           "https://claude.com", "https://claude.com:443/x", "https://chatgpt.com/auth/login",
                           "https://auth.openai.com/log-in", "https://x.ai", "https://accounts.x.ai/sign-in",
                           "https://console.x.ai/"]

    static let goodUsers: [String] = ["owner", "owner@example.com", "a", "o'wner!~", String(repeating: "u", count: 100)]
    static let badUsers: [String] = ["", "own er", " owner", "owner ", "owner\n", "owner\r\n", "owner\t", "own\u{E9}r",
                           "owner\u{7F}", "\u{FEFF}owner", "owner\u{200B}", "owner\u{A0}", String(repeating: "u", count: 101)]

    static let goodValues: [String] = [exampleSecretValue, "abcdefgh", "p\u{E4}ssw\u{F6}rd-\u{20AC}-\u{4F8B}", "\"quoted\\value\"",
                             String(repeating: "a", count: 4096), String(repeating: "\u{20AC}", count: 1365),
                             "\u{1F511}\u{1F511}\u{1F511}\u{1F511}\u{1F511}\u{1F511}\u{1F511}\u{1F511}"]
    static let badValues: [String] = ["", "abcdefg", "\u{1F511}\u{1F511}\u{1F511}\u{1F511}", String(repeating: "a", count: 4097),
                            String(repeating: "\u{20AC}", count: 1366), "example value-0123", "example\tvalue-0123",
                            "example\nvalue-0123", "example\r\nvalue-0123", "example\u{A0}value-0123",
                            "example\u{1F}value-0123", "example\u{1C}value-0123", "example\u{0}value-0123",
                            "example\u{7F}value-0123", "example\u{85}value-0123", "example\u{2028}value-0123",
                            "example\u{3000}value-0123", "example\u{200B}value-0123", "example\u{200D}value-0123",
                            "example\u{AD}value-0123", "example\u{202E}value-0123", "\u{FEFF}example-value-0123",
                            "example-value-0123\u{FEFF}", "example\u{2060}value-0123", "example\u{E0041}value-0123"]

    /// **Each field has one form, and each form is a whole match.** A text with a line end after it fails, as does
    /// white space at an end and a character that is not ASCII where the form is ASCII: the form's own type would
    /// trim such a text, and two readers would then hold two texts.
    @Test func eachFieldHasOneForm() {
        for name in Self.goodNames { #expect(SaveSecret.isKeyName(name), "\(name)") }
        for name in Self.badNames { #expect(!SaveSecret.isKeyName(name), "\(name.debugDescription)") }
        for site in Self.goodSites { #expect(SaveSecret.isSite(site), "\(site)") }
        for site in Self.badSites { #expect(!SaveSecret.isSite(site), "\(site.debugDescription)") }
        for user in Self.goodUsers { #expect(SaveSecret.isUserName(user), "\(user)") }
        for user in Self.badUsers { #expect(!SaveSecret.isUserName(user), "\(user.debugDescription)") }
        #expect(Self.longSite.utf8.count == 300 && Self.longHost.utf8.count == 194)
        // A host of 253 characters is the longest, and a port has 1 to 5 digits.
        let label = String(repeating: "h", count: 253)
        #expect(SaveSecret.isSite("http://" + label) && !SaveSecret.isSite("http://" + label + "h"))
        #expect(SaveSecret.siteHost("https://api.example.com:8443/v1?x=1") == "api.example.com")
        #expect(SaveSecret.siteHost("https://claude.ai/login") == "claude.ai" && !SaveSecret.isSite("https://claude.ai/login"))

        // The same through the read of a call, with each field's own sentence: a line end after the field, and a
        // character that is not ASCII in it.
        let key = SaveSecretSample.key, login = SaveSecretSample.login
        let keyWithSite = SaveSecretSample.with(key, ["url": .string("https://api.example.com/v1")])
        let cases: [([String: JSONValue], String, String, String)] = [
            (key, "env", "EXAMPLE_API_KEY", SaveSecret.envWord),
            (keyWithSite, "url", "https://api.example.com/v1", SaveSecret.urlWord),
            (login, "url", "https://shop.example.com/login", SaveSecret.urlWord),
            (login, "username", "owner", SaveSecret.userWord),
            (key, "kind", "api_key", SaveSecret.kindWord),
            (login, "kind", "login", SaveSecret.kindWord),
            (key, "from", "clipboard", SaveSecret.fromWord),
            (key, "request_id", SaveSecretSample.id, SaveSecret.requestWord),
        ]
        for (base, field, good, words) in cases {
            #expect(SaveSecretSample.refusal(SaveSecretSample.with(base, [field: .string(good)])) == nil, "\(field)")
            for end in ["\n", "\r\n", "\r", " ", "\u{2028}", "\u{0}"] {
                let fields = SaveSecretSample.with(base, [field: .string(good + end)])
                #expect(SaveSecretSample.refusal(fields) == words, "\(field) \(end.debugDescription)")
                #expect(SaveSecretSample.refusal(SaveSecretSample.with(fields, ["request_id": .string(SaveSecretSample.id)]),
                                                 app: true) == (field == "request_id" ? nil : words), "\(field) in the app")
            }
            for odd in ["\u{E9}", "\u{FF21}", "\u{661}", "\u{200B}"] {
                let fields = SaveSecretSample.with(base, [field: .string(good + odd)])
                #expect(SaveSecretSample.refusal(fields) == words, "\(field) \(odd.debugDescription)")
                #expect(SaveSecretSample.refusal(SaveSecretSample.with(base, [field: .string(odd + good)])) == words)
            }
            // A field that is no text has no form at all.
            #expect(SaveSecretSample.refusal(SaveSecretSample.with(base, [field: .int(7)])) == words, "\(field)")
            #expect(SaveSecretSample.refusal(SaveSecretSample.with(base, [field: .array([.string(good)])])) == words)
        }
        // The app's read holds a line end after the id too (the loop above gave the app its own good id).
        let ended = SaveSecretSample.with(key, ["request_id": .string(SaveSecretSample.id + "\n")])
        #expect(SaveSecretSample.refusal(ended, app: true) == SaveSecret.requestWord)
    }

    /// **The form of a `request_id`**: a UUID in lower case with its hyphens, exactly 36 ASCII bytes. The program
    /// puts the letters A to F of a given id in lower case (`uuidgen` writes capitals) and changes no other
    /// character; the app takes lower case only.
    @Test func aRequestIdIsAUUIDInLowerCase() {
        let key = SaveSecretSample.key, id = SaveSecretSample.id
        func given(_ text: String, app: Bool = false) -> String? {
            SaveSecretSample.refusal(SaveSecretSample.with(key, ["request_id": .string(text)]), app: app)
        }
        #expect(given(id) == nil && given(id, app: true) == nil)
        #expect(given("0a1b2c3d-4e5f-6789-abcd-ef0123456789") == nil)
        let wrong = ["", "not-a-uuid", id + "0", String(id.dropLast()), id.replacingOccurrences(of: "-", with: ""),
                     "11111111-2222-4333-8444-55555555555g", "11111111x2222-4333-8444-555555555555",
                     "111111112-222-4333-8444-555555555555", "11111111-2222-4333-8444-55555555555\u{FF15}",
                     "11111111-2222-4333-8444-55555555555\u{665}", "{" + id + "}", "bws://" + id, " " + id]
        for text in wrong {
            #expect(given(text) == SaveSecret.requestWord, "\(text.debugDescription)")
            #expect(given(text, app: true) == SaveSecret.requestWord, "\(text.debugDescription) in the app")
        }
        // Capitals: the program puts A to F in lower case, and no other letter; the app takes none.
        let capitals = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEFFFF"
        #expect(given(capitals) == nil && given(capitals, app: true) == SaveSecret.requestWord)
        #expect(SaveSecret.read(["request_id": .string(capitals)], app: false) == .success(.state(id: capitals.lowercased())))
        #expect(given("GGGGGGGG-BBBB-4CCC-8DDD-EEEEEEEEFFFF") == SaveSecret.requestWord)
        #expect(given("\u{212A}AAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEFFFF") == SaveSecret.requestWord)
    }

    /// **The key name's rule is the hub's** (`lifecycle.py` `key_env`): the pattern, the endings and the reserved
    /// names, text for text. The Mac's older list (`LoginSecret.isReserved`) has no `XAI_`, so the tool has its own.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: OwnerSaveSecretFormTests.lifecycle.path)))
    func theKeyNameRuleIsTheHubs() throws {
        let source = try String(contentsOf: Self.lifecycle, encoding: .utf8)
        #expect(source.contains(#"KEY_ENV = re.compile(r"[A-Z][A-Z0-9_]{0,59}")"#))
        let endings = SaveSecret.keySuffixes.map { "\"\($0)\"" }.joined(separator: ", ")
        #expect(source.contains("KEY_SUFFIXES = (" + endings + ")\n"))
        // One pattern in two literals: the reserved starts, then the names that are reserved as a whole.
        let block = try #require(source.range(of: #"ENV_RESERVED = re\.compile\((?:\s*r"[^"]*")+\)"#,
                                              options: .regularExpression))
        let literal = try NSRegularExpression(pattern: #"r"([^"]*)""#)
        let text = String(source[block])
        let pattern = literal.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range(at: 1), in: text)!])
        }.joined()
        #expect(pattern == "(?:" + SaveSecret.reservedPrefixes.joined(separator: "|") + ")_[A-Z0-9_]*|"
                + SaveSecret.reservedNames.joined(separator: "|"))
        #expect(source.contains("return isinstance(name, str) and bool(KEY_ENV.fullmatch(name)) and "
                                + "name.endswith(KEY_SUFFIXES) \\\n        and not ENV_RESERVED.fullmatch(name)"))
    }

    /// What the words of `envWord` rest on, with no file: each reserved start is refused with every ending, and a
    /// name that is reserved as a whole has none of the endings, so the words need not name it.
    @Test func theReservedNamesAreRefusedAndTheWordsNameEachStart() {
        for start in SaveSecret.reservedPrefixes {
            for ending in SaveSecret.keySuffixes {
                #expect(!SaveSecret.isKeyName(start + ending) && !SaveSecret.isKeyName(start + "_EXAMPLE" + ending))
                #expect(SaveSecret.isKeyName("MY_" + start + ending) && SaveSecret.isKeyName(start + "S" + ending))
            }
            #expect(SaveSecret.envWord.contains(start + "_"))
        }
        for name in SaveSecret.reservedNames {
            #expect(!SaveSecret.isKeyName(name))
            #expect(!SaveSecret.keySuffixes.contains { name.hasSuffix($0) }, "\(name)")
        }
        for ending in SaveSecret.keySuffixes { #expect(SaveSecret.envWord.contains(ending)) }
        #expect(SaveSecret.reservedPrefixes.contains("XAI"))
    }

    /// **The provider sites are the vault's** (`vault.py` `provider_site`): the two lists and the rule that reads
    /// them, text for text.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: OwnerSaveSecretFormTests.vault.path)))
    func theProviderSitesAreTheVaults() throws {
        let source = try String(contentsOf: Self.vault, encoding: .utf8)
        func tuple(_ list: [String]) -> String { "(" + list.map { "\"\($0)\"" }.joined(separator: ", ") + ")" }
        #expect(source.contains("\nPROVIDER_SITES = " + tuple(SaveSecret.providerSites)))
        #expect(source.contains("\nPROVIDER_KEY_SITES = " + tuple(SaveSecret.providerKeySites)))
        #expect(source.contains("""
                host = str(host or "").lower().rstrip(".")
                if any(host == site or host.endswith("." + site) for site in PROVIDER_KEY_SITES):
                    return False
                return any(host == site or host.endswith("." + site) for site in PROVIDER_SITES)
            """))
        // The vault's bound for a value that gets a fingerprint is the tool's shortest value.
        #expect(source.contains("return len(value) >= \(SaveSecret.valueLeast) and not re.search(r\"\\s\", value)"))
    }

    /// The vault's rule on hosts, with no file: a site, a name under it, and the two key sites with the names under
    /// them. The words of `urlWord` name each site.
    @Test func aProvidersSignInSiteIsNoSite() {
        for site in SaveSecret.providerSites {
            #expect(SaveSecret.isProviderSite(site) && SaveSecret.isProviderSite("www." + site))
            #expect(!SaveSecret.isProviderSite("not" + site) && !SaveSecret.isProviderSite(site + ".example.com"))
            #expect(!SaveSecret.isSite("https://" + site + "/") && !SaveSecret.isSite("http://sign.in." + site + ":8443/x"))
            #expect(SaveSecret.urlWord.contains(site))
        }
        for site in SaveSecret.providerKeySites {
            #expect(!SaveSecret.isProviderSite(site) && !SaveSecret.isProviderSite("eu." + site))
            #expect(SaveSecret.isSite("https://" + site + "/v1"))
            #expect(SaveSecret.urlWord.contains(site))
        }
        #expect(SaveSecret.providerKeySites.contains("api.x.ai"))
    }

    /// **Every value that passes has a password fingerprint**, by the rule that every vault uses
    /// (`SecretFingerprint.of`, which is `vault.py` `fingerprints`): a value with none would get an entry in the list
    /// that the vault refuses at every try. Also: each character that takes a value's fingerprint away is refused by
    /// the form, over every Unicode scalar.
    @Test func everyValueThatPassesHasAPasswordFingerprint() throws {
        let salts = SecretSalts(login: SaveSecretSample.reference, password: "00112233445566778899aabbccddeeff",
                                totp: "ffeeddccbbaa99887766554433221100")
        func fingerprints(_ value: String) throws -> [SecretFingerprint] {
            var secret = LoginSecret()
            secret.kind = .apiKey
            secret.env = "EXAMPLE_API_KEY"
            secret.password = value
            return try SecretFingerprint.of(try secret.value(), salts: salts)
        }
        for value in Self.goodValues {
            #expect(SaveSecret.isValueText(value), "\(value.prefix(12))")
            let made = try fingerprints(value)
            #expect(made.count == 1 && made.first?.kind == "password", "\(value.prefix(12))")
            #expect(made.first?.len == value.unicodeScalars.count && SecretFingerprint.areValid(made))
        }
        for value in Self.badValues { #expect(!SaveSecret.isValueText(value), "\(value.prefix(12).debugDescription)") }
        // The two dead ends of the form: a short value and a value with white space have no fingerprint.
        #expect(try fingerprints("abcdefg").isEmpty && fingerprints("example value-0123").isEmpty)
        #expect(try fingerprints("example\u{1F}value-0123").isEmpty)
        var refused = 0
        for number in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(number), SecretFingerprint.isWhitespace(scalar) else { continue }
            refused += 1
            var text = String.UnicodeScalarView()
            text.append(contentsOf: "example".unicodeScalars)
            text.append(scalar)
            text.append(contentsOf: "value-0123".unicodeScalars)
            #expect(!SaveSecret.isValueText(String(text)), "U+\(String(number, radix: 16))")
        }
        #expect(refused == PyText.space.count && refused == 29)
    }

    /// **The app never cuts or changes a value: it takes off only the one line end of a file or of stdin.** From a
    /// file or from stdin (`line` true), the value is the one line that the text holds: exactly one line end at the
    /// very end, one LF or one CR LF, is the line's end and no part of the value. Nothing else is taken off: no
    /// space, no tab, no second line end, no lone CR and no invisible character, at the start or at the end. From the
    /// clipboard (`line` false), the text is taken as it is, a line end at its end too. What is left has the value's
    /// form, or the text is no value: a text with white space at an end is refused, and never saved without it.
    @Test func onlyTheOneLineEndOfAFileOrOfStdinIsTakenOffAValue() {
        let value = exampleSecretValue
        func line(_ text: String?) -> String? { SaveSecret.value(of: text, line: true) }
        func copied(_ text: String?) -> String? { SaveSecret.value(of: text, line: false) }
        // One line: with no line end, with a LF and with a CR LF.
        #expect(line(value) == value && line(value + "\n") == value && line(value + "\r\n") == value)
        #expect(line("abcdefgh") == "abcdefgh" && line("abcdefgh\n") == "abcdefgh" && line("abcdefgh\r\n") == "abcdefgh")
        // Nothing else is taken off, at the end or at the start: each of these is no value.
        let cut = ["abcdefgh\n\n", "abcdefgh\r\n\r\n", "abcdefgh\n\r\n", "abcdefgh\r\n\n", "abcdefgh\r\r\n",
                   "abcdefgh \n", "abcdefgh\t\n", "abcdefgh \r\n", "abcdefgh ", "abcdefgh\t", " abcdefgh", " abcdefgh\n",
                   "\tabcdefgh\n", "\nabcdefgh", "\nabcdefgh\n", "\r\nabcdefgh\r\n", "abcdefgh\r", "abcdefgh\n\r",
                   "\rabcdefgh\n", "abcdefgh\u{A0}", "abcdefgh\u{A0}\n", "abcdefgh\u{200B}", "abcdefgh\u{200B}\n",
                   "\u{200B}abcdefgh", "\u{200B}abcdefgh\n", "\u{FEFF}abcdefgh", "\u{FEFF}abcdefgh\n", "abcdefgh\u{FEFF}",
                   "abcdefgh\u{2028}", "abcdefgh\u{2029}", "abcdefgh\u{85}", "abcdefgh\u{0B}", "abcdefgh\u{0C}",
                   "abcdefgh\u{1F}\n", "abcdefgh\u{0}"]
        for text in cut {
            #expect(line(text) == nil, "\(text.debugDescription)")
            #expect(copied(text) == nil, "\(text.debugDescription) from the clipboard")
        }
        #expect(cut.count == 35 && Set(cut).count == 35)
        // From the clipboard the text is taken as it is: a line end at its end is not taken off.
        #expect(copied(value) == value && copied("abcdefgh") == "abcdefgh")
        for text in ["abcdefgh\n", "abcdefgh\r\n", value + "\n", value + "\r\n"] {
            #expect(copied(text) == nil, "\(text.debugDescription)")
            #expect(line(text) != nil, "\(text.debugDescription)")
        }
        // No text at all, and a text that is only its line end.
        for text in [nil, "", "\n", "\r\n", "\r", " \n ", " "] as [String?] {
            #expect(line(text) == nil && copied(text) == nil, "\(text.debugDescription)")
        }
        // The bounds are of the value, not of the text that came.
        #expect(line("abcdefg\n") == nil && line("abcdefg\r\n") == nil && copied("abcdefg") == nil)
        let longest = String(repeating: "a", count: SaveSecret.valueMost)
        #expect(line(longest + "\n") == longest && line(longest + "\r\n") == longest && copied(longest) == longest)
        #expect(line(longest + "a\n") == nil && line(longest + "a") == nil && copied(longest + "a") == nil)
        // White space inside is no value, from each source.
        #expect(line("example value-0123") == nil && copied("example value-0123") == nil)
        #expect(line("example\nvalue-0123\n") == nil && line("example\r\nvalue-0123") == nil)
        // The value that comes out is the text itself, scalar for scalar: nothing in it is changed. A letter with
        // a combining mark stays two scalars, and a CR LF inside the text is not read as a line's end.
        let marked = "pa\u{308}ssword-e\u{301}-0123"
        #expect(line(marked + "\r\n").map { Array($0.unicodeScalars) } == Array(marked.unicodeScalars))
        #expect(copied(marked).map { Array($0.unicodeScalars) } == Array(marked.unicodeScalars))
        #expect(marked.unicodeScalars.count == 17 && line(marked)?.unicodeScalars.count == 17)
        // The form itself, and the words that say it.
        #expect(!SaveSecret.isValueText("\u{FEFF}" + value) && !SaveSecret.isValueText(value + "\u{200B}"))
        #expect(!SaveSecret.isValueText(value + "\n") && !SaveSecret.isValueText(" " + value))
        #expect(SaveSecret.valueLeast == 8 && SaveSecret.valueMost == 4096)
        #expect(SaveSecret.notAValue.contains("8 characters or more, at most 4096 bytes"))
        #expect(SaveSecret.notAValue.contains("no white space and no invisible character"))
        #expect(SaveSecret.notAValue.contains("takes off only the one line end of a file or of stdin, and nothing else"))
    }

    /// **An invisible character is never saved with the value, and never taken off it.** Inside the text, at its
    /// start and at its end, a zero-width character, a byte order mark, a soft hyphen and a control character each
    /// make the text no value, from a file and from the clipboard: nothing can say whether the owner's value has it,
    /// so the app does not cut it and does not save it. `abcdefgh` with a zero-width space (U+200B) at an end is
    /// refused: it is not saved as `abcdefgh`.
    @Test func anInvisibleCharacterIsNeverSavedWithTheValue() {
        let value = exampleSecretValue
        var refused = 0
        for invisible in ["\u{200B}", "\u{FEFF}", "\u{200D}", "\u{2060}", "\u{AD}", "\u{202E}", "\u{0}", "\u{7F}"] {
            for text in [invisible + value, value + invisible, invisible + value + invisible,
                         "example" + invisible + "-value-0123", value + invisible + "\n", invisible + value + "\n",
                         value + invisible + "\r\n", "abcdefgh" + invisible, invisible + "abcdefgh\n"] {
                for line in [true, false] {
                    #expect(SaveSecret.value(of: text, line: line) == nil, "\(text.debugDescription), line \(line)")
                    refused += 1
                }
            }
        }
        #expect(refused == 8 * 9 * 2)
        // The same text with no such character is the value.
        #expect(SaveSecret.value(of: value + "\n", line: true) == value && SaveSecret.value(of: value, line: false) == value)
        #expect(SaveSecret.value(of: "abcdefgh\u{200B}", line: true) != "abcdefgh")
    }

    /// **Every site that a login takes gives a title of the host and the user name only**, never with a path or a
    /// query. The form's type makes a login's title of the host that it reads in the address (`LoginSecret.title`),
    /// and takes the whole address when it reads none: such a title would put the path and the query into the hub's
    /// list, its git history and its log. So for every sample site, and for sites made of the form's own alphabet
    /// (each character that a path takes, a "%" with two hex digits, with and without a port, the longest host), the
    /// form's type takes the secret and its title is "host · user name". For a key, the hub's step takes the address
    /// that the form's rule makes of the site, which has no path and no query.
    @Test func everySiteThatALoginTakesGivesATitleOfTheHostAndTheUserNameOnly() throws {
        let features = [SecretCommand.keyTableFeature]
        let sites = Self.goodSites + Self.generatedSites()
        #expect(sites.count > 150)
        for site in sites {
            let short = site.count > 80 ? String(site.prefix(40)) + "…" + String(site.suffix(30)) : site
            #expect(SaveSecret.isSite(site), "\(short)")
            let host = try #require(SaveSecret.siteHost(site), "\(short)")
            var login = LoginSecret()
            login.kind = .login
            login.url = site
            login.username = "owner"
            login.password = exampleSecretValue
            #expect(login.problem == nil, "\(short)")
            let title = login.title
            if host.contains("xn--") {
                // A name in that coding: the form's type shows the name that it stands for.
                #expect(title == "b\u{FC}cher.example.com · owner", "\(short)")
            } else {
                #expect(title == Self.cut(host + " · owner"), "\(short): \(title)")
            }
            #expect(Self.holdsNoPath(title), "\(short): \(title)")
            #expect(throws: Never.self, "\(short)") {
                try SecretCommand.add(requestID: UUID(), database: "gen-1", login: SaveSecretSample.reference,
                                      title: title, kind: .login, variable: nil,
                                      address: SecretCommand.address(for: login, features: features), fingerprints: [])
            }
            var key = LoginSecret()
            key.kind = .apiKey
            key.env = "EXAMPLE_API_KEY"
            key.url = site
            key.password = exampleSecretValue
            #expect(key.problem == nil && key.title == "EXAMPLE_API_KEY", "\(short)")
            let address = SecretCommand.address(for: key, features: features)
            #expect(throws: Never.self, "\(short)") {
                try SecretCommand.add(requestID: UUID(), database: "gen-1", login: SaveSecretSample.reference,
                                      title: key.title, kind: .apiKey, variable: key.variable, address: address,
                                      fingerprints: [])
            }
            if let address {
                #expect(address.hasPrefix("https://") && Self.holdsNoPath(String(address.dropFirst(8))), "\(address)")
            } else {
                #expect(site.hasPrefix("http://"), "\(short)")
            }
        }
        // **A host that the form's type does not read.** A label that begins with "xn--" and is no name in that
        // coding passes the tool's form, and the form's type then reads no host (measured on macOS, 15 November
        // 2026): it refuses the secret, and the tool answers `formRefused`. The rule that must hold whatever that
        // type reads: a secret that it takes has a title with no path in it.
        for site in ["https://xn--example-9ua.example.com/pathmark?querymark=1", "https://xn--a.example.com/pathmark",
                     "https://a.xn--b:8443/pathmark", "https://xn--.example.com/?querymark=1"] {
            #expect(SaveSecret.isSite(site), "\(site)")
            var login = LoginSecret()
            login.kind = .login
            login.url = site
            login.username = "owner"
            login.password = exampleSecretValue
            #expect(login.problem != nil || Self.holdsNoPath(login.title), "\(site): \(login.title)")
            var key = LoginSecret()
            key.kind = .apiKey
            key.env = "EXAMPLE_API_KEY"
            key.url = site
            key.password = exampleSecretValue
            let address = SecretCommand.address(for: key, features: features)
            #expect(address.map { Self.holdsNoPath(String($0.dropFirst(8))) } ?? true, "\(site)")
        }
    }

    /// Sites made of the form's own alphabet: each mark that a path takes and a "%" with two hex digits, alone and
    /// in a query; one path with every letter, digit and mark; each with and without a port; and the longest host.
    static func generatedSites() -> [String] {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        let marks = Array("._~!$&'()*+,;=:@/?-").map { String($0) } + ["%41", "%2f", "%7E"]
        let all = "/pathmark" + letters + marks.joined() + "?querymark=" + marks.joined()
        var sites: [String] = []
        for port in ["", ":8443"] {
            for mark in marks {
                sites.append("https://example.com" + port + "/pathmark" + mark + "y")
                sites.append("https://example.com" + port + "/pathmark?querymark" + mark + "=" + mark)
                sites.append("http://example.com" + port + "/" + mark)
            }
        }
        for host in ["example.com", "a", "203.0.113.7", "a-b.c--d.example.com"] {
            for port in ["", ":0", ":443", ":8443", ":65535", ":99999", ":00443"] {
                sites.append("https://" + host + port)
                sites.append("https://" + host + port + all)
            }
        }
        let longest = String(repeating: String(repeating: "a", count: 62) + ".", count: 3) + String(repeating: "b", count: 64)
        for port in ["", ":8443"] {
            sites.append("https://" + longest + port)
            sites.append("https://" + longest + port + "/pathmark?querymark=1")
            sites.append("http://" + longest + port + "/")
        }
        return sites
    }

    /// A login's title as the form's type cuts it: at most 60 characters, the last one "…" for a longer one.
    static func cut(_ full: String) -> String {
        full.unicodeScalars.count <= LoginSecret.maxLabel ? full
            : String(String.UnicodeScalarView(full.unicodeScalars.prefix(LoginSecret.maxLabel - 1))) + "…"
    }

    /// Whether a text holds nothing of an address but a host, a port and a user name: no "/", no "?", no scheme, and
    /// neither of the two words that the generated sites have in their path and their query.
    static func holdsNoPath(_ text: String) -> Bool {
        !text.contains("/") && !text.contains("?") && !text.contains("http") && !text.contains("pathmark")
            && !text.contains("querymark")
    }

    /// **The longest value fits the vault's item.** With the longest address and user name, and a value whose every
    /// byte doubles in the item's JSON, the form's own type still takes the secret: the bound of 4096 bytes keeps the
    /// item under what a sealed copy carries.
    @Test func theLongestValueFitsTheVaultsItem() {
        var secret = LoginSecret()
        secret.kind = .login
        secret.url = Self.longSite
        secret.username = String(repeating: "u", count: 100)
        secret.password = String(repeating: "\"", count: SaveSecret.valueMost)
        #expect(SaveSecret.isSite(secret.url) && SaveSecret.isUserName(secret.username))
        #expect(SaveSecret.isValueText(secret.password))
        #expect(secret.problem == nil)
        #expect((try? secret.value().count) ?? 0 > 2 * SaveSecret.valueMost)
        #expect(SaveSecret.listMost == LoginSecret.maxCatalog)
    }

    /// **Every site of a key gives an address that the command takes.** For each address that `isSite` takes, the
    /// hub's step with the address that the form's rule makes of it (`SecretCommand.address`) does not throw: a throw
    /// there would read as an outcome that is not known. A login never gives an address.
    @Test func everySiteOfAKeyGivesAnAddressThatTheCommandTakes() throws {
        let features = [SecretCommand.keyTableFeature]
        var withAddress = 0
        for site in Self.goodSites {
            var secret = LoginSecret()
            secret.kind = .apiKey
            secret.env = "EXAMPLE_API_KEY"
            secret.url = site
            secret.password = exampleSecretValue
            let address = SecretCommand.address(for: secret, features: features)
            if address != nil { withAddress += 1 }
            #expect(throws: Never.self, "\(site)") {
                try SecretCommand.add(requestID: UUID(), database: "gen-1", login: SaveSecretSample.reference,
                                      title: secret.title, kind: .apiKey, variable: secret.variable, address: address,
                                      fingerprints: [])
            }
            if site.hasPrefix("http://") { #expect(address == nil, "\(site)") }
            #expect(SecretCommand.address(for: secret, features: []) == nil)
            secret.kind = .login
            secret.username = "owner"
            #expect(SecretCommand.address(for: secret, features: features) == nil)
        }
        #expect(withAddress >= 15)
        func address(_ site: String) -> String? {
            var secret = LoginSecret()
            secret.kind = .apiKey
            secret.env = "EXAMPLE_API_KEY"
            secret.url = site
            secret.password = exampleSecretValue
            return SecretCommand.address(for: secret, features: features)
        }
        #expect(address("https://api.example.com/v1") == "https://api.example.com")
        #expect(address("https://example.com:8443/a/b?c=d&e=f") == "https://example.com:8443")
    }
}

/// **The program's side of `save_secret`** (the secrets plan, step E1): the read of a call's fields, in its order,
/// and the plan that the program makes of it. No test here needs the app, a socket or the tool in the program's list.
struct OwnerSaveSecretPlanTests {
    let key = SaveSecretSample.key
    let login = SaveSecretSample.login
    let id = SaveSecretSample.id

    private func plan(_ fields: [String: JSONValue], free: Bool = true, newID: () -> String = { "made" }) -> SaveSecret.Plan? {
        if case .success(let plan) = SaveSecret.plan(fields, standardInputFree: free, newID: newID) { return plan }
        return nil
    }

    /// **The program makes the id, sends no path, and reads no source for a read of the state.**
    @Test func thePlanMakesTheIdSendsNoPathAndReadsNoSourceForAStateRead() throws {
        // A new save with no id: the program makes one, and says that it did.
        let fromFile = SaveSecretSample.with(key, ["from": .string("file"), "path": .string("/tmp/example")])
        let first = try #require(plan(fromFile, newID: { id }))
        #expect(first.made == id && first.source == .file("/tmp/example"))
        #expect(first.send == ["request_id": .string(id), "kind": .string("api_key"), "env": .string("EXAMPLE_API_KEY"),
                               "from": .string("file")])
        // The program's own maker: a UUID in lower case, another one for each call, which the app's read takes.
        let one = try #require(try SaveSecret.plan(fromFile, standardInputFree: true).get().made)
        let two = try #require(try SaveSecret.plan(fromFile, standardInputFree: true).get().made)
        #expect(one != two && UUID(uuidString: one) != nil && one == one.lowercased())
        #expect(SaveSecret.read(["request_id": .string(one)], app: true) == .success(.state(id: one)))
        // A given id is kept, and the plan does not call it made. Capitals of `uuidgen` go in lower case.
        var asked = 0
        let given = try #require(plan(SaveSecretSample.with(fromFile, ["request_id": .string(id)]),
                                      newID: { asked += 1; return "made" }))
        #expect(given.made == nil && given.send["request_id"] == .string(id) && given.send["path"] == nil)
        let capitals = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEFFFF"
        let lowered = try #require(plan(SaveSecretSample.with(login, ["request_id": .string(capitals)]),
                                        newID: { asked += 1; return "made" }))
        #expect(lowered.send["request_id"] == .string(capitals.lowercased()) && lowered.made == nil)
        #expect(lowered.source == .clipboard)
        #expect(lowered.send == ["request_id": .string(capitals.lowercased()), "kind": .string("login"),
                                 "url": .string("https://shop.example.com/login"),
                                 "username": .string("owner@example.com"), "from": .string("clipboard")])
        // Only the id: a read of the state. The plan names no source, sends the id alone and makes no id.
        let state = try #require(plan(["request_id": .string(id)], newID: { asked += 1; return "made" }))
        #expect(state.source == nil && state.send == ["request_id": .string(id)] && state.made == nil)
        // A field with null was not given: this is the same read of the state.
        let nulls = try #require(plan(["request_id": .string(id), "kind": .null, "from": .null, "path": .null],
                                      newID: { asked += 1; return "made" }))
        #expect(nulls == state)
        #expect(asked == 0)
        // No field at all is no read of a state: it is a save with no kind, and no id is made for a refused call.
        #expect(SaveSecretSample.planRefusal([:]) == SaveSecret.kindWord)
        var made = 0
        _ = SaveSecret.plan(["kind": .string("login")], standardInputFree: true, newID: { made += 1; return id })
        #expect(made == 0)
        // An API key's address goes with the fields; a field with null does not.
        let withSite = try #require(plan(SaveSecretSample.with(key, ["url": .string("https://api.example.com/v1"),
                                                                     "username": .null])))
        #expect(withSite.send["url"] == .string("https://api.example.com/v1") && withSite.send["username"] == nil)
        #expect(withSite.send.count == 5)
    }

    /// **`from` stdin is refused in the MCP form**, whose standard input carries the protocol, after every other
    /// check of the fields. A file, the clipboard and a read of the state are taken there.
    @Test func thePlanRefusesStdinInTheMCPForm() throws {
        let piped = SaveSecretSample.with(key, ["from": .string("stdin")])
        #expect(SaveSecretSample.planRefusal(piped, standardInputFree: false) == SaveSecret.stdinInMCP)
        #expect(SaveSecret.stdinInMCP.contains("founderizer-cli write") && SaveSecret.stdinInMCP.hasSuffix("Nothing was sent."))
        let fromPipe = try #require(plan(piped, free: true))
        #expect(fromPipe.source == .stdin && fromPipe.send["from"] == .string("stdin"))
        // The fields' own checks come first.
        #expect(SaveSecretSample.planRefusal(SaveSecretSample.with(piped, ["env": .string("example")]), standardInputFree: false)
                == SaveSecret.envWord)
        #expect(SaveSecretSample.planRefusal(SaveSecretSample.with(piped, ["path": .string("/tmp/example")]),
                                             standardInputFree: false) == SaveSecret.pathOnlyWithFile)
        let fromFile = SaveSecretSample.with(key, ["from": .string("file"), "path": .string("/tmp/example")])
        #expect(plan(key, free: false)?.source == .clipboard)
        #expect(plan(fromFile, free: false)?.source == .file("/tmp/example"))
        let state = try #require(plan(["request_id": .string(id)], free: false))
        #expect(state.source == nil)
    }

    /// **A field named like a value, a field of a seed and an unknown field**, each with its own sentence, whatever
    /// the field holds and in this order.
    @Test func aFieldNamedLikeAValueASeedFieldAndAnUnknownFieldAreRefused() {
        for name in ["value", "password", "token", "api_key", "Secret", "totp_secret", "seed_token"] {
            #expect(SaveSecretSample.planRefusal(SaveSecretSample.with(key, [name: .string("x")])) == OwnerLinkTools.neverAField)
            #expect(SaveSecretSample.planRefusal(SaveSecretSample.with(key, [name: .null])) == OwnerLinkTools.neverAField)
            #expect(SaveSecretSample.refusal(SaveSecretSample.with(key, [name: .string("x")]), app: true)
                    == OwnerLinkTools.neverAField)
        }
        for name in ["seed_from", "seed_path"] {
            #expect(SaveSecretSample.planRefusal(SaveSecretSample.with(login, [name: .string("file")])) == SaveSecret.noSeedYet)
            #expect(SaveSecretSample.planRefusal(SaveSecretSample.with(login, [name: .null])) == SaveSecret.noSeedYet)
            #expect(SaveSecretSample.refusal(SaveSecretSample.with(login, [name: .string("file")]), app: true)
                    == SaveSecret.noSeedYet)
        }
        #expect(SaveSecret.noSeedYet.contains("Add 2FA code") && SaveSecret.noSeedYet.hasSuffix("Nothing was sent."))
        for name in ["totp", "title", "account", "replace", "delete", "grant", "site", "Kind", "request-id", ""] {
            #expect(SaveSecretSample.planRefusal(SaveSecretSample.with(key, [name: .bool(true)])) == SaveSecret.only, "\(name)")
            #expect(SaveSecretSample.planRefusal(SaveSecretSample.with(key, [name: .null])) == SaveSecret.only, "\(name)")
        }
        for name in SaveSecret.fields { #expect(SaveSecret.only.contains(name)) }
        // The order of the three: a name of a value's kind, then a seed, then an unknown field.
        let all = SaveSecretSample.with(key, ["token": .string("x"), "seed_from": .string("file"), "more": .int(1)])
        #expect(SaveSecretSample.planRefusal(all) == OwnerLinkTools.neverAField)
        #expect(SaveSecretSample.planRefusal(all.filter { $0.key != "token" }) == SaveSecret.noSeedYet)
        #expect(SaveSecretSample.planRefusal(all.filter { $0.key == "more" || key[$0.key] != nil }) == SaveSecret.only)
        // No field of the tool is one that these rules refuse.
        for name in SaveSecret.fields {
            #expect(!OwnerLinkTools.namedLikeAValue(name) && !SaveSecret.seedFields.contains(name))
        }
    }

    /// **The checks run in their order**: of two faults in one call, the earlier check's sentence is the answer.
    @Test func theChecksOfTheFieldsRunInTheirOrder() {
        let with = SaveSecretSample.with
        func said(_ fields: [String: JSONValue], app: Bool = false) -> String? { SaveSecretSample.refusal(fields, app: app) }
        // An unknown field before the id; the id before the kind.
        #expect(said(with(key, ["more": .int(1), "request_id": .string("x")])) == SaveSecret.only)
        #expect(said(["request_id": .string("x"), "kind": .string("x")]) == SaveSecret.requestWord)
        #expect(said(["request_id": .int(7)]) == SaveSecret.requestWord)
        // The kind before its fields; the fields of the kind before any form.
        #expect(said(["kind": .string("card"), "env": .string("x")]) == SaveSecret.kindWord)
        #expect(said(["from": .string("clipboard")]) == SaveSecret.kindWord)
        #expect(said(["kind": .int(1)]) == SaveSecret.kindWord)
        #expect(said(with(login, ["env": .string("bad name")])) == SaveSecret.kindFields)
        #expect(said(with(key, ["username": .string("bad name")])) == SaveSecret.kindFields)
        #expect(said(login.filter { $0.key != "url" }) == SaveSecret.kindFields)
        #expect(said(login.filter { $0.key != "username" }) == SaveSecret.kindFields)
        #expect(said(key.filter { $0.key != "env" }) == SaveSecret.kindFields)
        #expect(said(with(login, ["url": .null])) == SaveSecret.kindFields)
        #expect(said(with(key, ["env": .string("bad"), "username": .string("owner")])) == SaveSecret.kindFields)
        // A login with env null and a key with username null are a login and a key.
        #expect(said(with(login, ["env": .null])) == nil && said(with(key, ["username": .null, "url": .null])) == nil)
        // The forms, in the order env, url, username; each before from and path.
        #expect(said(with(key, ["env": .string("bad"), "url": .string("bad"), "from": .string("bad")])) == SaveSecret.envWord)
        #expect(said(with(key, ["url": .string("bad"), "from": .string("bad")])) == SaveSecret.urlWord)
        #expect(said(with(login, ["url": .string("bad"), "username": .string("b a d")])) == SaveSecret.urlWord)
        #expect(said(with(login, ["username": .string("b a d"), "from": .string("bad")])) == SaveSecret.userWord)
        #expect(said(with(key, ["url": .string("https://claude.ai/login")])) == SaveSecret.urlWord)
        // from, then path, then how the two go together.
        #expect(said(with(key, ["from": .string("paste"), "path": .string("")])) == SaveSecret.fromWord)
        #expect(said(with(key, ["from": .bool(true)])) == SaveSecret.fromWord)
        #expect(said(with(key, ["from": .null, "path": .string("  ")])) == SaveSecret.pathWord)
        #expect(said(with(key, ["path": .int(3)])) == SaveSecret.pathWord)
        #expect(said(key.filter { $0.key != "from" }) == SaveSecret.needsFrom)
        #expect(said(with(key, ["from": .string("file")])) == SaveSecret.fileNeedsPath)
        #expect(said(with(key, ["path": .string("/tmp/example")])) == SaveSecret.pathOnlyWithFile)
        #expect(said(with(key, ["from": .string("stdin"), "path": .string("/tmp/example")])) == SaveSecret.pathOnlyWithFile)
        #expect(said(with(key, ["from": .string("file"), "path": .string("/tmp/example")])) == nil)
        // What the read gives for a call that it takes.
        #expect(SaveSecret.read(with(login, ["request_id": .string(id)]), app: false)
                == .success(.save(id: id, secret: .init(kind: .login, url: "https://shop.example.com/login",
                                                        username: "owner@example.com"), from: "clipboard", path: nil)))
        #expect(SaveSecret.read(with(key, ["from": .string("file"), "path": .string("/tmp/example")]), app: false)
                == .success(.save(id: nil, secret: .init(kind: .apiKey, env: "EXAMPLE_API_KEY"), from: "file",
                                  path: "/tmp/example")))
    }

    /// **The app's read**: the same checks, and two rules of its own. It needs `request_id`, because an id that the
    /// app made would be lost with a lost answer; and it takes no path, because the program reads the file.
    @Test func theAppNeedsTheIdAndTakesNoPath() {
        let with = SaveSecretSample.with
        func said(_ fields: [String: JSONValue]) -> String? { SaveSecretSample.refusal(fields, app: true) }
        #expect(said(key) == SaveSecret.appNeedsRequest && said([:]) == SaveSecret.appNeedsRequest)
        #expect(said(with(key, ["request_id": .null])) == SaveSecret.appNeedsRequest)
        // Before the kind and after an unknown field, as the id's own form is.
        #expect(said(["kind": .string("card")]) == SaveSecret.appNeedsRequest)
        #expect(said(["more": .int(1)]) == SaveSecret.only)
        let mine = with(key, ["request_id": .string(id)])
        #expect(said(mine) == nil)
        #expect(SaveSecret.read(["request_id": .string(id)], app: true) == .success(.state(id: id)))
        #expect(said(with(mine, ["from": .string("file"), "path": .string("/tmp/example")])) == SaveSecret.appTakesNoPath)
        #expect(said(with(mine, ["path": .string("/tmp/example")])) == SaveSecret.appTakesNoPath)
        // The program sent no path for from file, so the app asks for none.
        #expect(SaveSecret.read(with(mine, ["from": .string("file")]), app: true)
                == .success(.save(id: id, secret: .init(kind: .apiKey, env: "EXAMPLE_API_KEY"), from: "file", path: nil)))
        // The app takes what the program's plan sends, for each source.
        for from in ["file", "stdin", "clipboard"] {
            var fields = with(login, ["from": .string(from)])
            if from == "file" { fields["path"] = .string("/tmp/example") }
            guard case .success(let plan) = SaveSecret.plan(fields, standardInputFree: true) else {
                Issue.record("refused: \(from)"); continue
            }
            #expect(said(plan.send) == nil, "\(from)")
        }
        #expect(SaveSecret.appNeedsRequest.hasSuffix("Nothing was sent.") && SaveSecret.appTakesNoPath.hasSuffix("Nothing was sent."))
    }

    /// **The refusals quote nothing**, as far as the read and the plan go: the marker as each field's text, as a
    /// field's name, in a seed field, in a field named like a value and as the path. No refusal holds it, and a plan
    /// that is taken sends no path.
    @Test func theRefusalsQuoteNothing() {
        let with = SaveSecretSample.with
        var cases: [[String: JSONValue]] = []
        for base in [key, login, with(key, ["request_id": .string(id)]), [:]] {
            for field in SaveSecret.fields + SaveSecret.seedFields + ["token", marker, marker + "_secret"] {
                cases.append(with(base, [field: .string(marker)]))
                cases.append(with(base, [field: .array([.string(marker)])]))
                cases.append(with(base, [field: .object([marker: .string(marker)])]))
            }
            cases.append(with(base, ["from": .string("file"), "path": .string(marker)]))
            cases.append(with(base, ["from": .string("stdin"), "path": .string(marker)]))
            cases.append(with(base, ["url": .string("https://" + marker + ".example.com/"), "from": .string(marker)]))
            cases.append(with(base, ["env": .string(marker.uppercased() + "_KEY")]))
            cases.append(with(base, ["kind": .string(marker), "env": .string(marker), "url": .string(marker),
                                     "username": .string(marker), "request_id": .string(marker)]))
        }
        var refusals = 0, taken = 0
        for fields in cases {
            var texts: [String] = []
            for app in [false, true] {
                if case .failure(let refusal) = SaveSecret.read(fields, app: app) { texts.append(refusal.text) }
            }
            for free in [false, true] {
                switch SaveSecret.plan(fields, standardInputFree: free, newID: { id }) {
                case .failure(let refusal): texts.append(refusal.text)
                case .success(let plan):
                    taken += 1
                    #expect(plan.send["path"] == nil)
                    // What a taken plan sends holds the marker only in a field that had it in a form of its own.
                    for (name, value) in plan.send where value.string?.lowercased().contains(marker) == true {
                        #expect(["url", "username", "env"].contains(name), "\(name)")
                    }
                }
            }
            for text in texts {
                refusals += 1
                #expect(!text.lowercased().contains(marker) && !text.lowercased().contains("zq"), "\(text)")
                #expect(text.hasSuffix("Nothing was sent."), "\(text)")
            }
        }
        #expect(refusals > 400 && taken > 0)
    }
}

/// **The words of `save_secret`**: the tool as the program will list it, its description, and its fixed sentences
/// (the secrets plan, step E1).
struct OwnerSaveSecretWordsTests {
    /// **The tool is a write with no required field, and it is listed.** A read of a save's state sends only
    /// `request_id`, so the schema has no `required` list. The tool is the third of `OwnerLinkTools.names` and
    /// `tools`, one time in each, so the program lists it and sends it to the app. (It was the last one until
    /// `grant_secret`, `share_secret` and `answer_secret_request` came after it.)
    @Test func theToolIsAWriteWithNoRequiredFieldAndIsListed() throws {
        let tool = SaveSecret.tool
        #expect(tool.name == "save_secret" && SaveSecret.name == "save_secret" && tool.what == "save_secret")
        #expect(tool.annotations == .object(["readOnlyHint": .bool(false)]))
        #expect(OwnerTools.verb(of: tool) == .write)
        #expect(tool.inputSchema["required"] == nil)
        #expect(tool.inputSchema["additionalProperties"] == .bool(false))
        let properties = try #require(tool.inputSchema["properties"]?.object)
        #expect(Set(properties.keys) == Set(SaveSecret.fields) && properties.count == 7)
        #expect(properties["kind"]?["enum"] == .array([.string("login"), .string("api_key")]))
        #expect(properties["from"]?["enum"] == .array([.string("file"), .string("stdin"), .string("clipboard")]))
        for (name, schema) in properties {
            #expect(schema["type"] == .string("string"), "\(name)")
            #expect(!OwnerLinkTools.namedLikeAValue(name), "\(name)")
        }
        #expect(tool.feature == nil && tool.route.isEmpty && !tool.requestIDFromArguments)
        #expect(tool.firstSentence == "Saves a new login or a new API key of the fleet into the fleet's central vault.")
        #expect(SaveSecret.Kind.login.rawValue == LoginSecret.Kind.login.rawValue)
        #expect(SaveSecret.Kind.apiKey.rawValue == LoginSecret.Kind.apiKey.rawValue)
        #expect(OwnerLinkTools.names.firstIndex(of: SaveSecret.name) == 2 && OwnerLinkTools.names.count == 6)
        #expect(OwnerLinkTools.names.filter { $0 == SaveSecret.name }.count == 1)
        #expect(OwnerLinkTools.tools.count == 6 && OwnerLinkTools.tools[2].name == SaveSecret.name)
        #expect(OwnerLinkTools.tools[2].description == tool.description)
        // Not a tool of owner_mcp.py's table: a tool of the program only.
        #expect(Fixture.table.tool(SaveSecret.name) == nil)
    }

    /// **What the description must say**, sentence for sentence, in its three groups (what the tool saves and the
    /// fields of each kind; the value and its three sources; `request_id` and the answers), and what it must not: no
    /// word of it says that an agent can read a login. The sentences that carry a rule are held whole.
    @Test func theDescriptionSaysWhatItMust() throws {
        let words = SaveSecret.tool.description
        // Held whole, word for word: each of these carries a rule that an agent acts on.
        let neverInAChat = "The value (a login's password, or the key) is never a field of this tool, never a word of "
            + "a command line and never a word of a chat."
        let neverSeen = "You never see it, type it or repeat it, and you never ask the owner to paste it into a chat."
        let fromStdin = "from stdin: only with founderizer-cli write, the standard input from a program's pipe (never "
            + "pbpaste or another read of the clipboard: for the clipboard, use from clipboard), never an echo or a "
            + "here-string of the value; the MCP form refuses it."
        let fromClipboard = "from clipboard: the app reads the clipboard itself, after every other check passed, once "
            + "the owner copied the value and said so; never read the clipboard yourself."
        let theName = "A login's name in the fleet's list is the host of its url with its username, and a key's name "
            + "is its env: put nothing secret in them."
        let theSite = "For an API key with an https url, only the scheme, the host and the port go to the hub, which "
            + "can then set the key's site from its own table of well-known services; fleet_read(page=\"team\") shows "
            + "whether it did. The whole address stays in the value that the vault keeps, and this tool sets no site."
        let running = "A save can take longer than its call: then the answer says state running, with stage "
            + "registering or storing, and the save goes on. Read its state later with only request_id, until state "
            + "done or a refusal."
        for sentence in [neverInAChat, neverSeen, fromStdin, fromClipboard, theName, theSite, running] {
            #expect(words.contains(sentence), "\(sentence)")
        }
        #expect(words.contains(neverInAChat + " " + neverSeen))
        let sentences = [
            "Saves a new login or a new API key of the fleet into the fleet's central vault.",
            "It gives the secret to no agent.",
            "It replaces nothing: a name that the fleet's list of secrets has already is refused.",
            "kind: login or api_key.",
            "A login takes url (the address of its sign-in page) and username, and no env.",
            "An API key takes env (its variable name: capital letters, digits and _, with _KEY, _TOKEN, _SECRET, "
                + "_PASSWORD or _PAT at its end), may take url (the address of its service), and takes no username.",
            "This tool takes no seed for one-time codes.",
            "It comes from this Mac: from a file or a pipe that founderizer-cli reads and sends to the Founderizer app "
                + "after the request, not as a field, or from the clipboard, which the app reads itself.",
            "from file, with path: a regular file of this Mac that holds only the value (at most 64 KiB).",
            "When macOS asks whether Founderizer may access the pasteboard, the owner presses Allow Paste.",
            "After a clipboard save the app clears the clipboard when nothing else changed it since the read, and the "
                + "answer's clipboard says cleared or kept.",
            "The value from a file or from stdin is the one line that the text holds: one line end after it is not "
                + "part of the value.",
            "The app takes nothing else off a value and changes nothing in it, so a value with white space at its "
                + "start or at its end, or a text of two lines, is refused.",
            "The value is text of 8 characters or more, at most 4096 bytes, with no white space and no invisible "
                + "character in it.",
            "request_id: a UUID that names one save.",
            "A new save gives its own or none: with none, founderizer-cli makes one, and an answer with a state names it.",
            "A later call has two forms.",
            "With only request_id, it reads the state of that save and changes nothing.",
            "With the same fields, the same from and the same request_id, it goes on with that save, which is never "
                + "made twice.",
            "With state done, the answer has reference (the secret's reference in the list), title and kind.",
            "No answer has the value, its length or a fingerprint of it.",
        ]
        for sentence in sentences { #expect(words.contains(sentence), "\(sentence)") }
        // The three groups, in their order: the fields, then the value, then request_id.
        let fields = try #require(words.range(of: "This tool takes no seed for one-time codes."))
        let value = try #require(words.range(of: neverInAChat))
        let form = try #require(words.range(of: "The value is text of 8 characters or more"))
        let request = try #require(words.range(of: "request_id: a UUID that names one save."))
        #expect(fields.upperBound < value.lowerBound && value.upperBound < form.lowerBound)
        #expect(form.upperBound < request.lowerBound)
        #expect(words.hasPrefix(sentences[0]) && words.hasSuffix(sentences[sentences.count - 1]))
        // Plain words: none of the four terms that a reader has to know first, and no "in lower case" for an id
        // that the program puts in lower case itself.
        for term in ["as a part after the request", "joins that save", "sealed value", "the names under them",
                     "in lower case"] {
            #expect(!words.contains(term), "\(term)")
        }
        // The words for from, path, stdin and the clipboard are those of save_bot_token's description. Two sentences
        // are the same in both, with "the token" for "the value": the one about stdin, with its rule about the
        // clipboard, and the one that keeps the secret out of a chat.
        let theirs = SaveBotToken.tool.description
        #expect(theirs.contains(fromStdin.replacingOccurrences(of: "the value", with: "the token")))
        #expect(fromStdin.components(separatedBy: "the value").count == 2)
        #expect(theirs.contains(neverSeen))
        for clause in ["from stdin: only with founderizer-cli write, the standard input from a program's pipe",
                       ", never an echo or a here-string of the",
                       "; the MCP form refuses it. from clipboard: the app reads the clipboard itself, after every "
                       + "other check passed, once the owner copied the",
                       " and said so; never read the clipboard yourself. When macOS asks",
                       "When macOS asks whether Founderizer may access the pasteboard, the owner presses Allow Paste. "
                       + "After a clipboard save the app clears the clipboard when nothing else changed it since the "
                       + "read, and the answer's clipboard says cleared or kept."] {
            #expect(words.contains(clause) && theirs.contains(clause), "\(clause)")
        }
        // The one place that names an agent says that none gets the secret, and nothing says that one reads it.
        #expect(words.components(separatedBy: "agent").count == 2 && words.contains("to no agent"))
        for word in ["read a login", "reads a login", "read the login", "reads the login", "read the secret"] {
            #expect(!words.contains(word), "\(word)")
        }
        #expect(!words.contains("\n") && !words.contains("  "))
    }

    /// **Each sentence that carries a rule is held whole, word for word.** An agent acts on these words: which entry
    /// it may remove, what it does after a refusal, and what it tells the owner. A change of one of them is a
    /// decision, and this test is where it shows.
    @Test func theRuleCarryingSentencesAreHeldWordForWord() {
        let reference = SaveSecretSample.reference
        #expect(SaveSecret.held == "The list has a secret of this name already, and save_secret saves only a new one: "
                + "the owner replaces a secret in Founderizer, on Secrets. Remove an entry with save_login only when an "
                + "answer of save_secret named its reference as an entry with no value. Nothing was sent.")
        #expect(SaveSecret.noWork == "The Founderizer app has no save of this request_id: nothing was saved, it ended "
                + "long ago, or the app started again since. Read fleet_read(page=\"team\"). If the list has no secret "
                + "of this name, nothing was saved: save again with a new request_id. If it has one, the save may have "
                + "ended: do not save it again and do not remove it, and ask the owner to look at it on Secrets.")
        #expect(SaveSecret.busy == "Another save_secret runs now. Call again when it has ended. If it is a save of "
                + "yours, read its state with its request_id. Nothing was sent.")
        #expect(SaveSecret.noPin == "This Mac pinned no key of the central vault yet. The owner sets up Founderizer "
                + "Vault in the app on this Mac. Nothing was sent.")
        #expect(SaveSecret.otherKey == "The central vault answers with another key than the one that this Mac pinned. "
                + "Tell the owner, and save nothing until the owner knows why: do not set the vault up again to get "
                + "past this. Nothing was sent.")
        #expect(SaveSecret.noRecovery == "The central vault holds no recovery key yet, so the hub takes no new secret. "
                + "The owner finishes Founderizer Vault's setup in the app. Nothing was sent.")
        #expect(SaveSecret.noVault == "The fleet's central vault does not answer the hub now, so no secret can be "
                + "saved. Call save_secret again in a moment. Nothing was saved.")
        #expect(SaveSecret.notAValue == "That is not a value that the vault keeps: text of 8 characters or more, at "
                + "most 4096 bytes, with no white space and no invisible character in it. The app takes off only the one "
                + "line end of a file or of stdin, and nothing else. Nothing was sent.")
        #expect(SaveSecret.notOnClipboard == "The Founderizer app got no value from the clipboard: no text of 8 "
                + "characters or more, at most 4096 bytes, with no white space and no invisible character in it is copied, "
                + "or macOS did not allow the read. Ask the owner to copy the value again, with no space and no line end "
                + "around it, to say when it is copied, and to press Allow Paste if macOS asks. Nothing was sent.")
        #expect(SaveSecret.envWord == "env must be the key's variable name: 1 to 60 characters of A-Z, 0-9 and _, with "
                + "a letter first, and with _KEY, _TOKEN, _SECRET, _PASSWORD or _PAT at its end. Reserved are FLEET_, "
                + "BWS_, LD_, DYLD_, ANTHROPIC_, CLAUDE_, CODEX_ and XAI_, and every name that begins with one of "
                + "them, because a session or a program uses such a name itself. Nothing was sent.")
        #expect(SaveSecret.urlWord == "url must be an address of at most 300 ASCII characters: http:// or https://, a "
                + "host of at most 253 characters of a to z, 0 to 9, dots and hyphens that starts and ends with a "
                + "letter or a digit, then an optional : and a port of 1 to 5 digits, then an optional path that starts with / "
                + "(a query comes after it, as /?a=b), with no space, no capital letter in the host, no user part and "
                + "no fragment, and a % only with two hex digits after it. A path takes only letters, digits and the "
                + "marks . _ ~ % ! $ & ' ( ) * + , ; = : @ / ? - in it. The host must not be a model provider's own "
                + "sign-in site: claude.ai, claude.com, chatgpt.com, auth.openai.com or x.ai, or a name that ends "
                + "with a dot and one of them. platform.claude.com and api.x.ai are allowed, with each name that ends "
                + "with a dot and one of them. Nothing was sent.")
        #expect(SaveSecret.userWord == "username must be 1 to 100 printable ASCII characters, with no space. Nothing "
                + "was sent.")
        #expect(SaveSecret.requestWord == "request_id must be a UUID, or absent in a new save. Nothing was sent.")
        #expect(SaveSecret.clipboardDenied == "macOS does not let the Founderizer app read the clipboard: the owner's "
                + "setting in System Settings, Privacy & Security, Paste from Other Apps. The owner saves the secret in "
                + "Founderizer, on Secrets, with Add secret, or names a file. Nothing was sent.")
        // The two that ask for the same call again name its id: a caller that gave none cannot know it.
        let id = SaveSecretSample.id
        #expect(SaveSecret.notInVault(reference, id: id) == "The list has the entry \(reference), and its value is not "
                + "in the vault yet. Call save_secret again with the same fields, the same from and request_id \(id).")
        #expect(SaveSecret.registerNotKnown(reference, id: id) == "Whether the hub took the entry \(reference) is not "
                + "known. Call save_secret again with the same fields, the same from and request_id \(id): it goes on "
                + "under the same reference.")
        #expect(SaveSecret.notInVault(reference, id: id) == "The list has the entry bws://aaaaaaaa-bbbb-4ccc-8ddd-"
                + "eeeeeeeeeeee, and its value is not in the vault yet. Call save_secret again with the same fields, "
                + "the same from and request_id 11111111-2222-4333-8444-555555555555.")
        // The app's own failures before and at the first send, each with its own words.
        #expect(SaveSecret.sealFailed == "The Founderizer app could not seal the value for the vault. Nothing was sent.")
        #expect(SaveSecret.vaultUnread == "The Founderizer app could not read the central vault's status from the hub. "
                + "Call save_secret again in a moment. Nothing was sent.")
        #expect(SaveSecret.endedBeforeBegin == "The call ended before the save began, so nothing was sent.")
        #expect(SaveSecret.endedDuringRead == "The call ended while it waited for the clipboard, so nothing was sent.")
        // Another key at a later run: the save has ended, the owner must know, and the entry may be there.
        #expect(SaveSecret.otherKeyLater(reference) == "The central vault answers now with another key than the one "
                + "that this Mac pinned, so the value was not sent, and this save has ended. Tell the owner, and "
                + "save nothing until the owner knows why: do not set the vault up again to get past this. If the "
                + "list has the entry \(reference), it has no value in the vault: remove it with save_login (login "
                + "\(reference), delete true).")
        // Its rule about the vault's Set up is `otherKey`'s own, word for word.
        let noSetUp = "Tell the owner, and save nothing until the owner knows why: do not set the vault up again to get "
            + "past this."
        #expect(SaveSecret.otherKey.contains(noSetUp) && SaveSecret.otherKeyLater(reference).contains(noSetUp))
        // What the words of `urlWord` say of the form is what the form does, part for part.
        #expect(SaveSecret.isSite("https://example.com/?a=b") && !SaveSecret.isSite("https://example.com?a=b"))
        #expect(SaveSecret.isSite("http://" + String(repeating: "h", count: 253)))
        #expect(!SaveSecret.isSite("http://" + String(repeating: "h", count: 254)))
        #expect(SaveSecret.isSite("https://example.com:12345") && !SaveSecret.isSite("https://example.com:123456"))
        #expect(SaveSecret.isSite("https://example.com/a%2f") && !SaveSecret.isSite("https://example.com/a%2"))
        for mark in "._~!$&'()*+,;=:@/?-" {
            #expect(SaveSecret.isSite("https://example.com/a\(mark)b"), "\(mark)")
            #expect(SaveSecret.urlWord.contains(" \(mark) "), "\(mark)")
        }
        for mark in "\"<>[]\\^`{|}# " { #expect(!SaveSecret.isSite("https://example.com/a\(mark)b"), "\(mark)") }
        #expect(SaveSecret.isSite("https://www.platform.claude.com/") && !SaveSecret.isSite("https://www.claude.com/"))
        // No sentence says "(its login, delete true)" any more: only an answer with a reference names an entry to remove.
        #expect(!SaveSecret.held.contains("delete true") && !SaveSecret.held.contains("fleet_read"))
    }

    /// **The sentences that this tool shares with `save_bot_token`** are that tool's words under this tool's name,
    /// with "the value" for "the token": a change of one of them is a change of both. One differs on purpose:
    /// `clipboardDenied` names the owner's other way for a secret, which is the app's own form.
    @Test func theSharedSentencesAreTheBotTokensUnderThisToolsName() {
        func mine(_ theirs: String) -> String {
            theirs.replacingOccurrences(of: "save_bot_token", with: "save_secret")
                .replacingOccurrences(of: "the token", with: "the value")
                .replacingOccurrences(of: "The token", with: "The value")
        }
        let pairs: [(String, String, String)] = [
            ("fromWord", SaveSecret.fromWord, SaveBotToken.fromWord),
            ("pathWord", SaveSecret.pathWord, SaveBotToken.pathWord),
            ("needsFrom", SaveSecret.needsFrom, SaveBotToken.needsFrom),
            ("fileNeedsPath", SaveSecret.fileNeedsPath, SaveBotToken.fileNeedsPath),
            ("pathOnlyWithFile", SaveSecret.pathOnlyWithFile, SaveBotToken.pathOnlyWithFile),
            ("appTakesNoPath", SaveSecret.appTakesNoPath, SaveBotToken.appTakesNoPath),
            ("stdinInMCP", SaveSecret.stdinInMCP, SaveBotToken.stdinInMCP),
            ("noValue", SaveSecret.noValue, SaveBotToken.noValue),
            ("clipboardTakesNoPart", SaveSecret.clipboardTakesNoPart, SaveBotToken.clipboardTakesNoPart),
            ("endedDuringRead", SaveSecret.endedDuringRead, SaveBotToken.endedDuringRead),
            ("clipboardBusy", SaveSecret.clipboardBusy, SaveBotToken.clipboardBusy),
            ("notReady", SaveSecret.notReady, SaveBotToken.notReady),
        ]
        for (name, own, theirs) in pairs {
            #expect(own == mine(theirs), "\(name)")
            #expect(!own.contains("token") && !own.contains("Discord"), "\(name)")
        }
        #expect(SaveSecret.only == "save_secret takes only kind, env, url, username, from, path and request_id. "
                + "Nothing was sent.")
        // `clipboardDenied`: the bot token's words but for one clause, the owner's other way.
        let ownWay = "The owner saves the secret in Founderizer, on Secrets, with Add secret, or names a file."
        let theirWay = "The owner pastes the token in the app's own page, or names a file."
        #expect(SaveBotToken.clipboardDenied.contains(theirWay) && SaveSecret.clipboardDenied.contains(ownWay))
        #expect(SaveSecret.clipboardDenied == SaveBotToken.clipboardDenied.replacingOccurrences(of: theirWay, with: ownWay))
        #expect(!SaveSecret.clipboardDenied.contains("token") && !SaveSecret.clipboardDenied.contains("own page"))
    }

    /// **Each refusal before the send says that nothing was sent**, and the few sentences that do not end in those
    /// words say why in their own: nothing was sent in other words, nothing was changed, or (for `noVault`, which is
    /// also the answer to the hub's 503 after the entry's request went out) that nothing was saved.
    @Test func eachRefusalBeforeTheSendSaysThatNothingWasSent() {
        let before = [SaveSecret.only, SaveSecret.fromWord, SaveSecret.pathWord, SaveSecret.needsFrom,
                      SaveSecret.fileNeedsPath, SaveSecret.pathOnlyWithFile, SaveSecret.appTakesNoPath,
                      SaveSecret.stdinInMCP, SaveSecret.noValue, SaveSecret.clipboardTakesNoPart,
                      SaveSecret.clipboardDenied, SaveSecret.clipboardBusy, SaveSecret.noSeedYet, SaveSecret.requestWord,
                      SaveSecret.appNeedsRequest, SaveSecret.kindWord, SaveSecret.kindFields, SaveSecret.envWord,
                      SaveSecret.urlWord, SaveSecret.userWord, SaveSecret.notAValue, SaveSecret.notOnClipboard,
                      SaveSecret.formRefused, SaveSecret.sealFailed, SaveSecret.vaultUnread, SaveSecret.noPin,
                      SaveSecret.otherKey, SaveSecret.noRecovery, SaveSecret.listUnread, SaveSecret.full, SaveSecret.held,
                      SaveSecret.busy, OwnerLinkTools.neverAField]
        for words in before { #expect(words.hasSuffix(" Nothing was sent."), "\(words)") }
        #expect(Set(before).count == before.count)
        #expect(SaveSecret.endedDuringRead.hasSuffix("so nothing was sent."))
        #expect(SaveSecret.endedBeforeBegin.hasSuffix("so nothing was sent."))
        #expect(SaveSecret.endedBeforeBegin != SaveSecret.endedDuringRead && !SaveSecret.endedBeforeBegin.contains("clipboard"))
        // The app's read of the vault's status that failed is not "the vault does not answer the hub".
        #expect(SaveSecret.vaultUnread != SaveSecret.noVault && !SaveSecret.vaultUnread.contains("does not answer"))
        #expect(SaveSecret.sealFailed != SaveSecret.formRefused && !SaveSecret.sealFailed.contains("fields"))
        #expect(SaveSecret.notReady.contains("so it sent nothing"))
        #expect(SaveSecret.otherFields.hasSuffix("Nothing was changed."))
        // True before the send and after the hub's 503: nothing was saved. "Nothing was sent." would be false there.
        #expect(SaveSecret.noVault.hasSuffix(" Nothing was saved.") && !SaveSecret.noVault.contains("Nothing was sent"))
        #expect(SaveSecret.noWork.hasSuffix("ask the owner to look at it on Secrets."))
        #expect(SaveSecret.full == "The list has 256 secrets and takes no more. Nothing was sent.")
        #expect(SaveSecret.notOnClipboard.contains("is copied, or macOS did not allow the read"))
        #expect(SaveSecret.notOnClipboard.contains("to say when it is copied, and to press Allow Paste if macOS asks"))
        #expect(SaveSecret.notOnClipboard.contains(SaveSecret.valueForm) && SaveSecret.notAValue.contains(SaveSecret.valueForm))
        // No fixed sentence names an agent, so none says that one reads a login.
        let all = before + [SaveSecret.endedDuringRead, SaveSecret.endedBeforeBegin, SaveSecret.notReady,
                            SaveSecret.otherFields, SaveSecret.noVault,
                            SaveSecret.noWork, SaveSecret.notKnownHere, SaveSecret.notKnownHereWithID(SaveSecretSample.id),
                            SaveSecret.notKnownState,
                            SaveSecret.hubRefused(status: 409),
                            SaveSecret.registerNotKnown(SaveSecretSample.reference, id: SaveSecretSample.id),
                            SaveSecret.notInVault(SaveSecretSample.reference, id: SaveSecretSample.id),
                            SaveSecret.otherKeyLater(SaveSecretSample.reference),
                            SaveSecret.vaultRefused(SaveSecretSample.reference),
                            SaveSecret.registerNeverKnown(SaveSecretSample.reference),
                            SaveSecret.neverInVault(SaveSecretSample.reference)]
        for words in all {
            #expect(!words.contains("agent"), "\(words)")
            #expect(!words.contains("\n") && !words.contains("  "), "\(words)")
        }
    }

    /// **The sentences after the send hold only what the app made or has**: the reference that the app made, the
    /// hub's status number, and, in the two that ask for the same call again, the save's own `request_id`. The words
    /// for a lost answer hold an id only when the program made it.
    @Test func theSentencesAfterTheSendHoldOnlyTheReferenceAndTheStatus() {
        let reference = SaveSecretSample.reference, id = SaveSecretSample.id
        #expect(SaveSecret.hubRefused(status: 409) == "The hub refused the new entry (status 409). Nothing was saved.")
        // The two that can answer a read of the state name the whole call: "the same way" would be that read again.
        // They name the id itself, one time: a caller that gave none cannot know it, and a refusal carries no id.
        for words in [SaveSecret.registerNotKnown(reference, id: id), SaveSecret.notInVault(reference, id: id)] {
            #expect(words.contains("Call save_secret again with the same fields, the same from and request_id \(id)"))
            #expect(!words.contains("in the same way") && !words.contains("the same request_id"))
            #expect(words.components(separatedBy: reference).count == 2)
            #expect(words.components(separatedBy: id).count == 2)
        }
        // The id is the one that came, and no other text: another id gives another sentence only in that place.
        let other = "00000000-0000-4000-8000-000000000001"
        #expect(SaveSecret.registerNotKnown(reference, id: other)
                == SaveSecret.registerNotKnown(reference, id: id).replacingOccurrences(of: id, with: other))
        #expect(SaveSecret.notInVault(reference, id: other)
                == SaveSecret.notInVault(reference, id: id).replacingOccurrences(of: id, with: other))
        // The words that end a save ask for a new id or for none, so they hold none.
        for words in [SaveSecret.vaultRefused(reference), SaveSecret.registerNeverKnown(reference),
                      SaveSecret.neverInVault(reference), SaveSecret.otherKeyLater(reference)] {
            let rest = words.replacingOccurrences(of: reference, with: "")
            #expect(rest.range(of: "[0-9a-f]{8}-[0-9a-f]{4}", options: .regularExpression) == nil, "\(words)")
            #expect(rest != words && !words.contains(id))
        }
        #expect(SaveSecret.otherKeyLater(reference).components(separatedBy: reference).count == 3)
        #expect(!SaveSecret.otherKeyLater(reference).contains("request_id"))
        // The vault's own refusal is a fact: the list has the entry, and the vault has no value for it.
        #expect(SaveSecret.vaultRefused(reference)
                == "The list has the entry \(reference) with no value in the vault. Remove it with save_login (login "
                + "\(reference), delete true), then save again with a new request_id.")
        // The last words of a save that did not end in its tries state no fact: after a hub step that stayed not
        // known, and after a copy that did not reach the vault as far as the app knows, the words are "may have".
        let mayHave = "The list may have the entry \(reference) with no value in the vault. Remove it with save_login "
            + "(login \(reference), delete true), then save again with a new request_id."
        #expect(SaveSecret.registerNeverKnown(reference) == mayHave)
        #expect(SaveSecret.neverInVault(reference) == mayHave)
        #expect(SaveSecret.neverInVault(reference) != SaveSecret.vaultRefused(reference))
        // A lost answer: the same call again with the same id, which the words give only when the program made it.
        let lost = SaveSecret.notKnownHere
        #expect(lost.contains("not known") && lost.contains("Allow Paste"))
        #expect(lost.contains("call save_secret again in the same way with the same request_id"))
        #expect(lost.contains("a save that began goes on, and it is not made twice"))
        #expect(lost.range(of: "[0-9a-f]{8}-[0-9a-f]{4}", options: .regularExpression) == nil)
        let made = SaveSecret.notKnownHereWithID(SaveSecretSample.id)
        #expect(made.hasPrefix(lost) && made.contains(SaveSecretSample.id) && made != lost)
        #expect(made.components(separatedBy: SaveSecretSample.id).count == 2)
        // A lost answer to a read of a save's state: the state was not read, and nothing was changed. No id, and
        // nothing of a save that may have begun.
        #expect(SaveSecret.notKnownState == "The Founderizer app did not answer in time, or the link ended, so the "
                + "state of this save was not read. Nothing was changed. Call save_secret again with only this "
                + "request_id.")
        #expect(SaveSecret.notKnownState.range(of: "[0-9a-f]{8}-[0-9a-f]{4}", options: .regularExpression) == nil)
        #expect(!SaveSecret.notKnownState.contains("not known") && !SaveSecret.notKnownState.contains("Allow Paste"))
    }
}
