import Foundation
import Testing
@testable import FleetCore

/// **The vectors of the guard of a key in a text** (`app/vectors/key-in-text.json`): what `KeyInText.first(in:)` finds
/// in each example text, as a place in its UTF-16 units, and what `KeyInText.looksRandom` says of each run. The Windows
/// app's library (`windows/Founderizer.Core`, `KeyInText.cs`) holds its own rule equal to this file, so the Mac, the
/// iPhone and a PC hold back the same words before they go.
///
/// **No file holds a key's whole shape as one literal**: GitHub's push protection reads such a literal as a real key
/// and refuses the tag of the public copy of the apps (`GuideExampleKey`). So each example key here is put together from
/// two parts, its body is made up, and the file holds each text as pieces of eight characters, which a reader joins.
///
/// With `FOUNDERIZER_VECTORS_OUT` set, the test writes the file into that folder (`app/vectors/make_vectors.py` does,
/// and its `--check` compares); without it, the test holds the committed file equal to what FleetCore gives now.
struct KeyInTextVectorsTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("vectors")
    static let file = "key-in-text.json"
    static let madeBy = "app/Tests/FleetCoreTests/KeyInTextVectorsTests.swift"

    /// A made-up key from its prefix and its body: no literal holds both.
    static func key(_ prefix: String, _ body: String) -> String { prefix + body }

    /// A run of 32 letters and digits with no shape of its own, which reads as random.
    static let random = "Xk7Qp2Lm9Rt4Vb8Nc3Wz6Hd1Jf5Gs0Ya"
    static let openAI = key("sk-proj-", "Q3vT9xLm2NpR7sKw4YbZ8cHj6FdA1eGu")
    /// A key that only its shape finds: 23 characters, too few for the random run, so a text that holds it tests the word
    /// boundary at the start of the shape and nothing else (the review of round 3).
    static let shapeOnly = key("sk-", "abcdefghij0123456789")
    static let gitHub = key("ghp_", "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8")
    static let privateKey = key("-----BEGIN OPENSSH ", "PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU=\n-----END ")
        + key("OPENSSH ", "PRIVATE KEY-----")

    /// Each text with what it shows: a key with a shape of its own, a run that reads as random, and words, names, hashes,
    /// paths and addresses that are no key.
    static let texts: [(what: String, text: String)] = [
        ("an OpenAI key in a sentence", "here: \(openAI) and more"),
        ("a key with a shape after its name", "OPENAI_API_KEY=" + openAI),
        ("a run after its name", "export STUDIO_TOKEN=" + random),
        ("a GitHub token", "token \(gitHub) ok"),
        ("an AWS key alone", key("AKIA", "IOSFODNN7EXAMPLE")),
        ("a run in a sentence", "use \(random) as the key"),
        ("a run in the query of a web address", "call https://api.example.test/v1/items?api_key=\(random) now"),
        ("a run after the fragment mark of a web address", "open https://example.com/page#\(random)"),
        ("a private key from its first line to its last", privateKey),
        ("a private key with no last line", key("-----BEGIN ", "RSA PRIVATE KEY-----") + "\nMIIEpAIBAAKCAQEA"),
        ("an Anthropic key", "my key " + key("sk-ant-", "api03-EXAMPLEexampleEXAMPLEexample0123")),
        ("a Stripe live key", key("sk_live_", "EXAMPLEexample0123456789")),
        ("a Stripe restricted test key", "use " + key("rk_test_", "EXAMPLEexample0123456789")),
        ("a Stripe webhook secret", key("whsec_", "EXAMPLEexampleEXAMPLE0123")),
        ("a fine-grained GitHub token", key("github_pat_", "11EXAMPLE0example0EXAMPLE0example0EXAMPLE0ex")),
        ("a GitLab token", key("glpat-", "EXAMPLEexample01234567")),
        ("a Slack bot token", key("xoxb-", "1234567890-EXAMPLEexample")),
        ("a Slack app token", key("xapp-", "1-A0EXAMPLE-12345")),
        ("a Google API key", key("AIza", "SyEXAMPLEexampleEXAMPLEexample01234")),
        ("a SendGrid key", key("SG.", "EXAMPLEexample0123.EXAMPLEexample0123456")),
        ("a Hugging Face token", key("hf_", "EXAMPLEexampleEXAMPLEex")),
        ("an npm token", "npm token " + key("npm_", "EXAMPLEexampleEXAMPLE012345678")),
        ("an xAI key", key("xai-", "EXAMPLEexampleEXAMPLEexample012345")),
        ("a signed token", key("eyJ", "hbGciOiJIUzI1NiJ9") + "." + key("eyJ", "zdWIiOiIxMjM0NTY3ODkwIn0")
            + ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"),
        ("the made-up key of the guide's tests", key("sk_test_", "EXAMPLEexample0123456789")),
        ("a key after words in other scripts and an emoji", "Clé für \u{1F600} " + openAI),
        ("an AWS temporary key", key("ASIA", "IOSFODNN7EXAMPLE")),
        ("a Groq key", key("gsk_", "EXAMPLEexampleEXAMPLE0123")),
        ("a Perplexity key", key("pplx-", "EXAMPLEexampleEXAMPLEexample0123")),
        ("an OpenRouter key", key("sk-or-v1-", "EXAMPLEexampleEXAMPLE0123456789")),
        // The edges where Apple's whitespace and ICU's word boundary differ from .NET's own (the review of round 2).
        ("a run after a web address and a zero-width space", "see https://example.com/page\u{200B}" + random),
        ("a key after a space and a combining mark", "key: \u{0301}" + shapeOnly),
        ("a key after a letter and a zero-width space", "a\u{200B}" + shapeOnly),
        ("a key after a space and a zero-width joiner", "key: \u{200D}" + shapeOnly),
        ("a key after a space and a spacing mark", "key: \u{0903}" + shapeOnly),
        ("a key after a letter outside the first plane", "\u{1D400}" + shapeOnly),
        ("a key after a letter number", "\u{2160}" + shapeOnly),
        ("a key's prefix inside a word", "the task-force-recommendations-2026 plan"),
        ("a run after a fragment mark and a variation selector", "https://example.com/doc#\u{FE0F}" + random),
        ("a run after an address's marks and a combining mark", "x://\u{0301}" + random),
        // Foundation's search, which reads a find as standing unless a non-spacing or enclosing mark or U+200C follows it
        // (the review of round 4)
        ("a run after a fragment mark and a zero-width joiner", "x://a#\u{200D}" + random),
        ("a run after a fragment mark and a spacing mark", "x://a#\u{0903}" + random),
        ("a run after a prepended mark and a fragment mark", "x://a\u{0600}#" + random),
        ("a run after an address's marks, a spacing mark and a path", "x://\u{0903}a/" + random),
        // Which find counts, and what the word before a run holds: a find that does not count is passed over, a
        // mark before the marks of an address cuts nothing, and the word starts after a pair (the review after
        // round 4)
        ("a run after a fragment mark and a zero-width non-joiner", "x://a#\u{200C}" + random),
        ("a run after a web address, its fragment mark and a zero-width non-joiner", "https://example.com/a#\u{200C}" + random),
        ("a run after a fragment mark and an enclosing mark", "x://a#\u{20DD}" + random),
        ("a run after an address's marks and a combining mark, then another address's marks", "x://\u{0301}x://a.b/" + random),
        ("a run after a fragment mark and a combining mark, then another fragment mark", "x://a#\u{0301}b#c" + random),
        ("a run after a query mark and a combining mark", "x://a?\u{0301}" + random),
        ("a run after a query mark that comes before an address's marks", "x?y://a.b/" + random),
        ("a run after an address and an emoji", "x://a/\u{1F600}" + random),
        ("a run in the path of a web address after a query mark in the words before it", "what?https://example.com/" + random),
        ("a run in the path of a web address in another's query", "https://a.example/go?next=https://b.example/" + random),
        ("an AWS key before a zero-width space", key("AKIA", "IOSFODNN7EXAMPLE") + "\u{200B}x"),
        ("an AWS key before a combining mark", key("AKIA", "IOSFODNN7EXAMPLE") + "\u{0301} ok"),
        ("an AWS key before a space", key("AKIA", "IOSFODNN7EXAMPLE") + " ok"),
        ("a run that ends before a key with a shape", "\(random) then \(gitHub)"),
        ("a run after a tab and before a new line", "the value\t\(random)\nnext line"),
        ("a run with base64's padding", "secret: Zm9vYmFyMTIzQUJDZGVmR0hJams0NTZMTU5vcFFSUw=="),
        ("a run after two equals signs", "a=b=" + random),
        ("a run of 31", "use \(random.dropLast()) as the key"),
        ("a name in camel case", "call thisIsAVeryLongFunctionNameForTesting123 now"),
        ("a commit's hash", "commit 3f786850e387550fdab836ed7e6dc881de23001b"),
        ("a hash in hex", "the token is 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b"),
        ("a reference of a login", "bws://8c2f9a4e-1b7d-4f3a-9e6c-2d5b8a1f7e30"),
        ("a path", "see /srv/example/agents/app/Sources/Founderizer/FleetView.swift"),
        ("the path of a web address", "https://example.com/aVeryLongPathSegment/withMoreText/andNumbers123"),
        ("the id of a document in a web address", "the plan is at https://docs.google.com/document/d/1aBcD3fGhIjKlMnOpQrStUvWxYz0123456789/edit please"),
        ("a run in the path of a web address", "https://example.com/files/\(random)/view"),
        ("words about a key", "Please save the OpenAI key for the studio agent today."),
        ("a variable's name", "OPENAI_API_KEY_FOR_THE_STUDIO_AGENT_2026"),
        ("a UUID", "the order is 550e8400-e29b-41d4-a716-446655440000"),
        ("a sentence with numbers", "Refund order 10452 for the customer and tell them it goes out on Tuesday at 9:30."),
        ("a prefix with too short a body", "sk-short and ghp_abc and AKIA1234"),
        ("a run of capitals and digits", "ref ABCDEF0123456789ABCDEF0123456789XYZ"),
        ("nothing", ""),
    ]

    /// Runs for `looksRandom`: names, hashes, paths and words, runs at each of its limits (few kinds of letters, few
    /// changes between kinds, many small letters in a row), and pseudo-random runs of 32 to 39 letters and digits from a
    /// fixed sequence, about 1 in 40 of which does not pass as random.
    static func runs() -> [String] {
        var runs = [random, String(random.dropLast()), "thisIsAVeryLongFunctionNameForTesting123", "3f786850e387550fdab836ed7e6dc881de23001b",
                    "ABCDEF0123456789ABCDEF0123456789XYZ", "/srv/example/agents/app/Sources/Founderizer",
                    "aaaaBBBB1111ccccDDDD2222eeeeFFFF3333", "Zm9vYmFyMTIzQUJDZGVmR0hJams0NTZMTU5vcFFSUw==",
                    "OPENAI_API_KEY_FOR_THE_STUDIO_AGENT_2026", "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAa1",
                    "abc//Xk7Qp2Lm9Rt4Vb8Nc3Wz6Hd1Jf5Gs0Ya", "1aBcD3fGhIjKlMnOpQrStUvWxYz0123456789",
                    "Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9Ab1Cd2Ef3Gh4Ij5Kl6", "Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0Uv1Wx2",
                    "ABCD1234abcdEFGH5678efghIJKL9012ijkl", "Xk7Qp2Lm9Rt4helloworldexampleVb8Nc3Wz6",
                    "Xk7Qp2Lm9Rt4Vb8helloNc3Wz6Hd1Jf5Gs0Yamore"]
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var seed: UInt64 = 20_261_122
        func next() -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 33)
        }
        for _ in 0..<120 {
            let count = 32 + next() % 8
            runs.append(String((0..<count).map { _ in letters[next() % letters.count] }))
        }
        return runs
    }

    /// The text as parts that a reader joins: each text is cut whole into pieces of eight UTF-16 units (nine where the
    /// eighth is the first half of a pair), because a key can stand where the rule finds none, or after the one that it
    /// finds.
    static func parts(_ text: String) -> [String] {
        let words = text as NSString
        guard words.length > 0 else { return [text] }
        var parts: [String] = []
        var at = 0
        while at < words.length {
            var length = min(8, words.length - at)
            if at + length < words.length, UTF16.isLeadSurrogate(words.character(at: at + length - 1)) { length += 1 }
            parts.append(words.substring(with: NSRange(location: at, length: length)))
            at += length
        }
        return parts
    }

    static func document() throws -> Data {
        let cases = texts.map { what, text -> [String: Any] in
            let found = KeyInText.first(in: text).map { NSRange($0, in: text) }
            return ["what": what, "text": parts(text),
                    "found": found.map { [$0.location, $0.length] } ?? NSNull()]
        }
        let document: [String: Any] = [
            "about": "What FleetCore's KeyInText finds in each example text (`found`: its first UTF-16 unit and its count of "
                + "them, or null), and what KeyInText.looksRandom says of each run. Join the parts of each text: no part "
                + "holds a key's whole shape. Every key here is made up.",
            "made_by": madeBy,
            "texts": cases,
            "runs": runs().map { ["run": $0, "random": KeyInText.looksRandom($0)] as [String: Any] },
        ]
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            + Data("\n".utf8)
    }

    @Test("The vectors of a key in a text are what FleetCore gives now")
    func theKeyVectorsAreTheCommittedFile() throws {
        let made = try Self.document()
        if let out = ProcessInfo.processInfo.environment["FOUNDERIZER_VECTORS_OUT"] {
            try made.write(to: URL(fileURLWithPath: out).appendingPathComponent(Self.file))
            return
        }
        let committed = try Data(contentsOf: Self.folder.appendingPathComponent(Self.file))
        #expect(committed == made, "app/vectors/\(Self.file) is not what FleetCore gives: run app/vectors/make_vectors.py")
    }
}
