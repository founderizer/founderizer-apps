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
        // The base64 of a picture in a `data:` address is no key, and nothing else in such an address is let through
        // (the knowledge page's Add file, 24 November 2026: a Markdown file with a picture in it read as 92 keys)
        ("a run in the base64 of a picture in Markdown", "![logo](data:image/png;base64,\(random))"),
        ("a run in the base64 of a picture's address alone", "data:image/png;base64,\(random)"),
        ("a run in a data address with no base64", "see data:text/plain,\(random)"),
        ("a run after a space in the base64 of a picture", "data:image/png;base64,AAA \(random)"),
        ("the base64 of a key in a data address of text",
         "see data:text/plain;base64," + Data(key("sk_live_", "EXAMPLEexample0123456789").utf8).base64EncodedString()),
        ("a run in a data address with no type", "data:;base64,\(random)"),
        ("a run after a picture in a line of JSON", "{\"logo\":\"data:image/png;base64,iVBORw0KGgo=\",\"api_key\":\"\(random)\"}"),
        ("a run right after a picture in Markdown", "![a](data:image/png;base64,iVBORw0KGgo=)token=\(random)"),
        // A picture ends for good, and only a picture's own letters stand in it (25 November 2026, the readers of the
        // Windows port: a later ";base64," of the word, and "=" inside the base64, opened the exemption again)
        ("the base64 of a key after a picture in a line of JSON",
         "{\"logo\":\"data:image/png;base64,iVBORw0KGgo=\",\"k\":\"data:text/plain;base64,"
             + Data(key("sk_live_", "EXAMPLEexample0123456789").utf8).base64EncodedString() + "\"}"),
        ("a run after a second base64 mark in a line of JSON", "{\"logo\":\"data:image/png;base64,iVBORw0KGgo=\",\"k\":\"x;base64,\(random)\"}"),
        ("a run after a base64 mark and a quote that ended the picture", "\"data:image/\",\"k\":\"x;base64,\(random)"),
        ("a run after a base64 mark and a comma in a picture's address", "data:image/png,x;base64,\(random)"),
        ("a run after a base64 mark and a colon in a picture's address", "data:image/png:x;base64,\(random)"),
        ("a run after a second base64 mark in a picture's address", "data:image/png;base64,iVBORw0KGgo;base64,\(random)"),
        ("a run after token= after a picture's padding", "data:image/png;base64,iVBORw0KGgo=token=\(random)"),
        ("a run right after a picture's padding", "data:image/png;base64,iVBORw0KGgo=\(random)"),
        ("a run after a picture's letters and a hyphen", "data:image/png;base64,iVBORw0KGgo-\(random)"),
        ("a run after a picture's letters and a low line", "data:image/png;base64,iVBORw0KGgo_\(random)"),
        ("a run after a base64 mark and a space after a picture", "![a](data:image/png;base64,AAA=) x;base64,\(random)"),
        ("a run in a picture's address with no base64", "data:image/svg+xml,\(random)"),
        // ... and what is a picture's base64 stays one
        ("a picture's base64 with a plus sign, a slash and digits", "data:image/png;base64,iVBOR0+/\(random)"),
        ("a picture's base64 to its padding", "data:image/png;base64,\(random)=="),
        ("a picture's base64 after its type's parameter", "data:image/svg+xml;charset=utf-8;base64,\(random)"),
        ("a picture's base64 after its type's name", "data:image/png;name=a%20b_c-d.png;base64,\(random)"),
        ("the base64 of the second picture of a word", "![a](data:image/png;base64,iVBORw0KGgo=)![b](data:image/jpeg;base64,\(random))"),
        ("the base64 of a picture right after a picture's padding", "data:image/png;base64,iVBORw0KGgo=data:image/png;base64,\(random)"),
        // The readers of the Windows port (25 November 2026): a picture longer than one run, and the edges of each part
        ("a picture's base64 longer than one run", "![logo](data:image/png;base64,\(String(repeating: random, count: 157)))"),
        ("a run after a base64 mark and a quote in a picture's type", "data:image/png\"x;base64,\(random)"),
        ("a run after a base64 mark and a closing bracket in a picture's type", "data:image/png)x;base64,\(random)"),
        ("a run after a base64 mark and an opening bracket in a picture's type", "data:image/png(x;base64,\(random)"),
        ("a run after a base64 mark and a slash in a picture's type", "data:image/png/x;base64,\(random)"),
        ("a run in a picture's type", "data:image/png;name=\(random)"),
        ("a run after a picture's type with no data:", "image/png;base64,\(random)"),
        ("a run after a base64 mark with no semicolon", "data:image/pngbase64,\(random)"),
        ("a run with a low line at its end in a picture", "data:image/png;base64,\(random)_"),
        ("a run with a hyphen late in it in a picture", "data:image/png;base64,\(random)-Ya"),
        ("a picture's base64 after its type's parameter in capitals", "data:image/svg+xml;charset=UTF-8;base64,\(random)"),
        ("a run after a base64 mark and an apostrophe in a picture's type", "data:image/png'x;base64,\(random)"),
        ("a run after a base64 mark and a square bracket in a picture's type", "data:image/png[x;base64,\(random)"),
        ("a run after a picture's type with another scheme", "x:image/png;base64,\(random)"),
        ("a run after a picture's double padding", "data:image/png;base64,AAAA==\(random)"),
        ("a run in a data address of text after a picture in a line of JSON",
         "{\"a\":\"data:image/png;base64,iVBO=\",\"b\":\"data:text/plain;base64,\(random)\"}"),
        // The three-copy validator's gaps (25 November 2026): the marks are written in small letters, and only base64's
        // ASCII letters stand in a picture
        ("a run after a picture's marks in capitals", "DATA:IMAGE/PNG;BASE64,\(random)"),
        ("a run after a base64 mark in capitals", "data:image/png;BASE64,\(random)"),
        ("a run after a letter with an accent in a picture's type", "data:image/png\u{E9};base64,\(random)"),
        ("a run after a letter with an accent in a picture's base64", "data:image/png;base64,AAA\u{E9}\(random)"),
        ("a run after an Arabic-Indic digit in a picture's base64", "data:image/png;base64,AAA\u{0663}\(random)"),
        ("a run after a full stop in a picture's base64", "data:image/png;base64,AAA.\(random)"),
        ("a run after a percent sign in a picture's base64", "data:image/png;base64,AAA%\(random)"),
        ("a run after a zero-width space in a picture's base64", "data:image/png;base64,AAA\u{200B}\(random)"),
        ("a run after an emoji in a picture's base64", "data:image/png;base64,AAA\u{1F600}\(random)"),
        // a mark newer than Unicode 15 (Python 3.12 has it as unassigned): each port holds the marks of a newer Unicode
        ("a run after the marks of an address and a combining mark newer than Unicode 15", "https://\u{1ACF}x/" + random),
        // held by choice: the end of an HTML comment glued to a picture's base64 makes its run no base64 (`inPicture`)
        ("a picture's base64 glued to the end of an HTML comment", "<!-- data:image/png;base64,\(random)-->"),
        // The edges that the hub's port of this rule met (the coordinator's validator, 24 November 2026)
        ("a run in the path of a web address after an emoji", "https://example.com/files/\u{1F600}" + random),
        ("a run in the path of a web address after a zero-width space", "https://example.com/files/\u{200B}" + random),
        ("a run in the path of a web address after a unit separator", "https://example.com/files/\u{001F}" + random),
        ("an AWS key before a circled digit", key("AKIA", "IOSFODNN7EXAMPLE") + "\u{2460}"),
        ("an AWS key before a fullwidth low line", key("AKIA", "IOSFODNN7EXAMPLE") + "\u{FF3F}"),
        // A spacing mark of Grapheme_Extend joins the mark before it, as a non-spacing mark does (reader 1 of round 2,
        // 25 November 2026): no address after "://" and it, and no query or fragment after "?" or "#" and it
        ("a run after the marks of an address and a halfwidth sound mark", "https://\u{FF9E}x/" + random),
        ("a run after the marks of an address and a Kannada vowel sign", "https://\u{0CC0}x/" + random),
        ("a run after a query mark and a Kannada vowel sign", "https://example.com/a?\u{0CC0}" + random),
        ("a run after a fragment mark and a Bengali vowel sign", "https://example.com/a#\u{09BE}" + random),
        // ICU's word boundary looks past each joiner of `tables.boundary_skips`, a spacing one and one of Apple's private
        // use too, and Foundation's search past each of `tables.address_marks` (the Door area's reader, 25 November 2026)
        ("a Slack token after a space and a Bengali vowel sign", " \u{09BE}" + key("xoxb-", "1234567890-EXAMPLEexample")),
        ("a Slack token after a space and a musical spacing mark", " \u{1D165}" + key("xoxb-", "1234567890-EXAMPLEexample")),
        ("an AWS key before one of Apple's private-use joiners", key("AKIA", "IOSFODNN7EXAMPLE") + "\u{F870}"),
        ("a run after the marks of an address and a mark of the BMP newer than Unicode 15", "https://\u{0897}x/" + random),
        // An address's facts belong to its word, not to the text (the Windows readers, 25 November 2026)
        ("a run in the next word after a web address", "https://example.com/commit/3f786850e387550fdab836ed7e6dc881de23001b " + random),
        ("a run in a web address's path after a word before it", "3f786850e387550fdab836ed7e6dc881de23001b https://example.com/files/" + random),
        // ICU's circled letters are letters of a word, and a squared sign beside them is not (App shell's Windows port)
        ("a key after a circled capital letter", "\u{24B6}" + shapeOnly),
        ("a key after a squared capital letter", "\u{1F130}" + shapeOnly),
        ("a key after a squared sign that is no letter", "\u{1F14A}" + shapeOnly),
        ("nothing", ""),
    ]

    /// **Texts whose saved form (`KeyInText.savedForm`, the hub's `knowledge_saved_text`) is not the text**: what a
    /// knowledge file's check reads, at the Mac, the PC and the hub alike (`saved` of the file: the text, its saved form,
    /// and the first find in the saved form).
    static let saved: [(what: String, text: String)] = [
        ("a private key whose lines end in CR LF", privateKey.replacingOccurrences(of: "\n", with: "\r\n")),
        ("a private key whose lines end in CR", privateKey.replacingOccurrences(of: "\n", with: "\r")),
        ("a run in the path of a web address after a unit separator", "https://example.com/files/\u{001F}" + random),
        ("a run in the path of a web address after a delete", "https://example.com/files/\u{007F}" + random),
        ("a run after a C1 control character", "use\u{0085}" + random + " now"),
        ("a run after a tab and a null", "token\t\u{0000}" + random),
        ("a CR LF and a lone CR before a run after its name", "line one\r\nline two\rexport STUDIO_TOKEN=" + random),
        ("a run before a CR at the very end", "export STUDIO_TOKEN=" + random + "\r"),
        ("a CR, a CR LF and a run after its name", "a\r\r\nexport STUDIO_TOKEN=" + random),
        ("an emoji and a CR LF before a run after its name", "\u{1F600}\r\nexport STUDIO_TOKEN=" + random),
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

    /// **The joiners that each port holds as written lists, not from its own Unicode data** (the readers of 25 November
    /// 2026: the hub's Python has Unicode 15.0, .NET and Apple each their own, and Apple's also counts some characters
    /// of private use), each measured on the Mac that writes the file, from the parts that KeyInText uses, as ranges
    /// of scalars `[first, last]`:
    /// - `address_marks`: each unit of the BMP after which Foundation's search of a word's "://", "?" or "#" does not
    ///   find it (KeyInText's `stands`; `theAddressRuleReadsMarksAsFoundationDoes` holds Swift's own rule to it);
    /// - `boundary_skips`: each scalar that ICU's `\b` (the shapes' word boundary, NSRegularExpression) looks past, as
    ///   it looks back for a word character, and before which it sees no boundary.
    /// Both are measured live, so `theKeyVectorsAreTheCommittedFile` can fail on a Mac whose system has other Unicode data
    /// than the Mac that wrote the file: that failure says the tables of the ports are due for a new measurement.
    static func tables() -> [String: Any] {
        func ranges(_ values: [UInt32]) -> [[UInt32]] {
            values.reduce(into: [[UInt32]]()) { out, value in
                if let last = out.last, last[1] + 1 == value { out[out.count - 1][1] = value } else { out.append([value, value]) }
            }
        }
        return [
            "about": "Joiners as ranges of scalars [first, last], measured on the Mac that wrote this file: address_marks, the "
                + "units of the BMP after which a word's \"://\", \"?\" or \"#\" does not count; boundary_skips, the "
                + "scalars that a shape's \\b looks past. Each port holds these lists, not its own Unicode data.",
            "address_marks": ranges(addressMarks()),
            "boundary_skips": ranges(boundarySkips()),
        ]
    }

    /// The units of the BMP after which Foundation's search does not find "://" (whitespace ends a word, so none). The
    /// search is NSString's, as the rule before searched a word that it took from an NSString: a Swift string of its own
    /// searches by Swift's wider grapheme clusters, which also join U+0903 or U+200D.
    static func addressMarks() -> [UInt32] {
        (0x01...0xFFFF).compactMap { value in
            guard let scalar = Unicode.Scalar(value), !CharacterSet.whitespacesAndNewlines.contains(scalar) else { return nil }
            return (("x://" + String(scalar) + "a") as NSString).range(of: "://").location == NSNotFound ? UInt32(value) : nil
        }
    }

    /// The scalars that ICU's `\b` looks past: a token after a space and the scalar is found, after a letter and the
    /// scalar it is not. Of the scalars outside the BMP only the marks, the format characters and Grapheme_Extend can be
    /// one, so only those are tried.
    static func boundarySkips() -> [UInt32] {
        let shape = try! NSRegularExpression(pattern: #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#)
        let token = key("xoxb-", "1234567890-EXAMPLEexample")
        func finds(_ text: String) -> Bool { shape.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
        let kinds: Set<Unicode.GeneralCategory> = [.nonspacingMark, .enclosingMark, .spacingMark, .format]
        return (0x01...0x10FFFF).compactMap { value in
            guard let scalar = Unicode.Scalar(value) else { return nil }
            if value > 0xFFFF, !kinds.contains(scalar.properties.generalCategory), !scalar.properties.isGraphemeExtend {
                return nil
            }
            let joiner = String(scalar)
            return finds(" " + joiner + token) && !finds("a" + joiner + token) ? UInt32(value) : nil
        }
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
            "tables": tables(),
            "saved": saved.map { what, text -> [String: Any] in
                let form = KeyInText.savedForm(text)
                let found = KeyInText.first(in: form).map { NSRange($0, in: form) }
                return ["what": what, "text": parts(text), "saved": parts(form),
                        "found": found.map { [$0.location, $0.length] } ?? NSNull()]
            },
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

    /// **KeyInText's address rule reads a joiner after "://" as Foundation's search did** (the rule before 24 November
    /// 2026 searched each word with Foundation): for each unit of the BMP, a run after "x://", the unit and "a/" stands
    /// in an address's path exactly when Foundation finds that "://". The bug that this catches: a joiner that Foundation
    /// reads as part of the "/" and the rule does not, so a key after it is let through as a path (U+FF9E, U+0897).
    @Test("KeyInText's address rule reads a joiner after :// as Foundation's search does")
    func theAddressRuleReadsMarksAsFoundationDoes() {
        let marks = Set(Self.addressMarks())
        var differ: [String] = []
        for value in 0x01...0xFFFF {
            // "?" and "#" begin the address's query or fragment there: the run after them is in no path, on either side
            guard value != 0x3F, value != 0x23 else { continue }
            guard let scalar = Unicode.Scalar(value), !CharacterSet.whitespacesAndNewlines.contains(scalar) else { continue }
            let before = "x://" + String(scalar) + "a/"
            let text = (before + Self.random) as NSString
            var words = KeyInText.Words(text)
            if words.inAddressPath((before as NSString).length) == marks.contains(UInt32(value)) {
                differ.append(String(format: "U+%04X", value))
            }
        }
        #expect(differ.isEmpty, "the address rule and Foundation's search differ at \(differ.prefix(20))")
    }
}
