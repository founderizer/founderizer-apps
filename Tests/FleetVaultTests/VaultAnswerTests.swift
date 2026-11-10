import Foundation
import Testing
@testable import FleetVaultCore

/// The answer of a `request`: the values that it must not show, what the vault keeps of it, its status line and its
/// reply. These are checks of `VaultAnswer` only, without a hub, a service or a child. Synthetic values only.
@Suite struct VaultAnswerTests {
    private static let key = "SYNTHETIC-KEY-0123456789"
    private static let seed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    /// The most bytes of a body that a reply shows.
    private static let cut = VaultCall.maxBody

    private static func login(_ password: String = key, totp: String? = nil) throws -> VaultLogin {
        var value = ["username": "api-user", "password": password, "url": "https://api.example.test"]
        value["totp"] = totp
        return try VaultLogin(data: JSONSerialization.data(withJSONObject: value), label: "Synthetic API")
    }
    private static func bytes(_ text: String) -> Data { Data(text.utf8) }
    private static func letters(_ count: Int) -> Data { Data(repeating: 0x61, count: count) }
    private static func text(_ count: Int) -> String { String(repeating: "a", count: count) }
    /// The Basic value of a request for `login(password)`.
    private static func basic(_ password: String) -> String { Data(("api-user:" + password).utf8).base64EncodedString() }
    /// A body of letters with `form` at byte `place`.
    private static func body(_ form: Data, at place: Int, count: Int = 100_000) -> Data {
        var body = letters(count)
        body.replaceSubrange(place..<(place + form.count), with: form)
        return body
    }

    /// The text of a JSON string for `value`, as a service can write it. `unicode`: the characters that become
    /// `\uXXXX`. Each other character is as it is, or it has the escape of two bytes when JSON permits no other form.
    private static func json(_ value: String, uppercase: Bool = false, slash: Bool = false,
                             unicode: (Int, Unicode.Scalar) -> Bool = { _, _ in true }) -> Data {
        let short: [Unicode.Scalar: String] = ["\"": "\\\"", "\\": "\\\\", "\u{8}": "\\b", "\u{c}": "\\f", "\n": "\\n", "\r": "\\r", "\t": "\\t"]
        var text = ""
        for (place, scalar) in value.unicodeScalars.enumerated() {
            if unicode(place, scalar) || (scalar.value < 0x20 && short[scalar] == nil) {
                for unit in String(scalar).utf16 { text += "\\u" + String(format: uppercase ? "%04X" : "%04x", unit) }
            } else if let escape = short[scalar] {
                text += escape
            } else if scalar == "/" && slash {
                text += "\\/"
            } else {
                text.unicodeScalars.append(scalar)
            }
        }
        return Data(text.utf8)
    }
    /// Forms that a JSON answer can give to one value: each character as `\uXXXX` in the two cases of the digits,
    /// only the characters that are not ASCII (the default of Python), only the necessary escapes without and with
    /// `\/`, and two mixes of escaped and plain characters.
    private static func codings(of value: String) -> [Data] {
        [json(value), json(value, uppercase: true), json(value) { _, scalar in !scalar.isASCII },
         json(value) { _, _ in false }, json(value, slash: true) { _, _ in false },
         json(value) { place, _ in place % 2 == 0 }, json(value, uppercase: true, slash: true) { place, _ in place % 2 == 1 }]
    }
    /// An accent, a quote with a backslash and a slash, a character outside the BMP, white space, and a value that
    /// has the text of an escape in it.
    private static let odd = ["stand-in-\u{e9}-value-0123456789", #"SYN"THETIC\KEY/0123"#, "key-\u{1f600}-0123456789", "two words\nwith\ttabs",
                              #"key\u0041-0123456789"#]

    /// What a reply gives: its text and `truncated`, or the reason for no text. `other`: a reply that does not have
    /// exactly the fields and the types of one of the two documented forms.
    private enum Answer: Equatable { case text(String, truncated: Bool), withheld(String), other }

    private static func answer(of reply: [String: Any], job: Int = 7, status: Int = 200) -> Answer {
        guard reply["ok"] as? Bool == true, reply["v"] as? Int == 2, reply["job"] as? Int == job, reply["status"] as? Int == status else { return .other }
        if reply.count == 5, let why = reply["withheld"] as? String { return .withheld(why) }
        if reply.count == 6, let text = reply["body"] as? String, let truncated = reply["truncated"] as? Bool { return .text(text, truncated: truncated) }
        return .other
    }

    /// The reply for a whole body, as the broker makes it: the vault keeps the first `keep(for:)` bytes and counts all
    /// bytes. Each reply is also checked here. Its encoded form has no value. A text is the first bytes of the body,
    /// without at most three bytes at a cut, and it has no value as it is or with its escapes resolved.
    private static func answer(_ body: Data, _ forms: [Data]) -> Answer {
        let reply = VaultAnswer.reply(job: 7, status: 200, kept: Data(body.prefix(VaultAnswer.keep(for: forms))), total: body.count, forms: forms)
        let encoded = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        #expect(!encoded.isEmpty)
        #expect(!forms.contains { encoded.range(of: $0) != nil })
        let given = answer(of: reply)
        if case .text(let text, let truncated) = given {
            let shown = Data(text.utf8), plain = VaultAnswer.unescaped(shown).text
            #expect(Data(body.prefix(shown.count)) == shown)
            #expect(truncated == (body.count > cut))
            #expect(truncated ? (cut - 3...cut).contains(shown.count) : shown.count == body.count)
            #expect(!forms.contains { shown.range(of: $0) != nil || plain.range(of: $0) != nil })
        }
        return given
    }

    // MARK: The values of a login

    @Test func theFormsOfALoginAreItsProtectedValuesAsTheyAre() throws {
        #expect(VaultAnswer.forms(of: try Self.login()) == [Self.bytes(Self.key)])
        // A quote, a backslash, a slash and white space are bytes of the value. The JSON forms are not in this list:
        // the reply resolves the escapes of the answer.
        for value in Self.odd { #expect(VaultAnswer.forms(of: try Self.login(value)) == [Self.bytes(value)]) }
        // A TOTP value and its seed.
        let uri = "otpauth://totp/Test?secret=gezdgnbv%20gy3tqojq-gezdgnbvgy3tqojq%3D"
        #expect(VaultAnswer.forms(of: try Self.login(totp: uri)) == [Self.bytes(Self.key), Self.bytes(uri), Self.bytes(Self.seed)])
        // A TOTP value that is its own seed is one value, and a TOTP value of fewer than 8 characters is none.
        #expect(VaultAnswer.forms(of: try Self.login(totp: Self.seed)) == [Self.bytes(Self.key), Self.bytes(Self.seed)])
        #expect(VaultAnswer.forms(of: try Self.login(totp: "JBSWY3D")) == [Self.bytes(Self.key)])
        #expect(VaultAnswer.forms(of: try Self.login(Self.seed, totp: Self.seed)) == [Self.bytes(Self.seed)])
    }

    @Test func theBasicValueIsAFormOnlyWithAProtectedPassword() throws {
        let token = Self.basic(Self.key)
        #expect(token == "YXBpLXVzZXI6U1lOVEhFVElDLUtFWS0wMTIzNDU2Nzg5")
        #expect(VaultAnswer.forms(of: try Self.login(), basic: token) == [Self.bytes(Self.key), Self.bytes(token)])
        // A request that is not Basic has no Basic value.
        #expect(VaultAnswer.forms(of: try Self.login()) == [Self.bytes(Self.key)])
        // A password of fewer than 8 characters is not protected, so its Basic value is not a form. A long TOTP value
        // of the same login does not change that.
        #expect(VaultAnswer.forms(of: try Self.login("short-7"), basic: Self.basic("short-7")).isEmpty)
        #expect(VaultAnswer.forms(of: try Self.login("short-7", totp: Self.seed), basic: Self.basic("short-7")) == [Self.bytes(Self.seed)])
    }

    @Test func aValueOfFewerThanEightCharactersIsNotAFormAndABodyWithItIsShown() throws {
        for short in ["x", "1234567", "short-7"] { #expect(VaultAnswer.forms(of: try Self.login(short)).isEmpty) }
        #expect(VaultAnswer.forms(of: try Self.login("12345678")) == [Self.bytes("12345678")])
        let none = VaultAnswer.forms(of: try Self.login("short-7"))
        #expect(Self.answer(Self.bytes("your key is short-7"), none) == .text("your key is short-7", truncated: false))
        // The same value in the escaped forms of a JSON answer is shown too.
        for coding in Self.codings(of: "short-7") {
            let body = Self.bytes(#"{"key":""#) + coding + Self.bytes(#""}"#)
            #expect(Self.answer(body, none) == .text(String(decoding: body, as: UTF8.self), truncated: false))
        }
        #expect(Self.answer(Self.bytes("your key is 12345678"), VaultAnswer.forms(of: try Self.login("12345678"))) == .withheld("key"))
    }

    // MARK: What the vault keeps

    @Test func theVaultKeepsTheShownPartAndSixBytesForEachByteOfTheLongestValue() throws {
        #expect(VaultAnswer.keep(for: []) == 65_536)
        #expect(VaultAnswer.keep(for: [Data([0x41])]) == 65_541)
        #expect(VaultAnswer.keep(for: [Self.bytes(Self.key)]) == 65_679)
        #expect(VaultAnswer.keep(for: [Data(count: 8), Data(count: 30), Data(count: 24)]) == 65_715)
        #expect(VaultAnswer.keep(for: VaultAnswer.forms(of: try Self.login(), basic: Self.basic(Self.key))) == 65_799)
        // No form of a JSON answer has more bytes for a value: six for each unit of UTF-16, and a character with more
        // bytes in UTF-8 has not more units.
        for value in Self.odd + [Self.key, Self.basic(Self.key), "\u{7ff}\u{800}\u{ffff}\u{10000}\u{10ffff}"] {
            let longest = Self.json(value)
            #expect(longest.count == 6 * value.utf16.count && longest.count <= 6 * value.utf8.count)
            for coding in Self.codings(of: value) { #expect(coding.count <= longest.count) }
        }
    }

    // MARK: A body that is shown

    @Test func aBodyOfTextIsShownAndALongBodyIsCutAtItsLimit() throws {
        let forms = VaultAnswer.forms(of: try Self.login())
        #expect(Self.answer(Self.bytes(#"{"things":[1,2]}"#), forms) == .text(#"{"things":[1,2]}"#, truncated: false))
        let mixed = "caf\u{e9} \u{20ac} \u{1f600}\n\ttab \u{0} end, and a path C:\\new\\table with \\u00e9"
        #expect(Self.answer(Self.bytes(mixed), forms) == .text(mixed, truncated: false))
        #expect(Self.answer(Data(), forms) == .text("", truncated: false))
        // Exactly the limit: all of it, and it is not cut. One byte more: the first 65,536 bytes, and it is cut.
        #expect(Self.answer(Self.letters(65_535), forms) == .text(Self.text(65_535), truncated: false))
        #expect(Self.answer(Self.letters(65_536), forms) == .text(Self.text(65_536), truncated: false))
        #expect(Self.answer(Self.letters(65_537), forms) == .text(Self.text(65_536), truncated: true))
        #expect(Self.answer(Self.letters(1_000_000), forms) == .text(Self.text(65_536), truncated: true))
        // The same for a login without a protected value.
        #expect(Self.answer(Self.letters(65_536), []) == .text(Self.text(65_536), truncated: false))
        #expect(Self.answer(Self.letters(65_537), []) == .text(Self.text(65_536), truncated: true))
    }

    @Test func aReplyHasExactlyItsDocumentedFieldsWithTheirTypes() throws {
        func wire(_ reply: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: reply, options: .sortedKeys), as: UTF8.self)
        }
        let forms = VaultAnswer.forms(of: try Self.login())
        let made = VaultAnswer.reply(job: 31, status: 201, kept: Self.bytes("made"), total: 4, forms: forms)
        #expect(try wire(made) == #"{"body":"made","job":31,"ok":true,"status":201,"truncated":false,"v":2}"#)
        #expect(Self.answer(of: made, job: 31, status: 201) == .text("made", truncated: false))
        let long = VaultAnswer.reply(job: 32, status: 200, kept: Self.letters(65_679), total: 100_000, forms: forms)
        #expect(try wire(long) == #"{"body":""# + Self.text(65_536) + #"","job":32,"ok":true,"status":200,"truncated":true,"v":2}"#)
        #expect(Self.answer(of: long, job: 32) == .text(Self.text(65_536), truncated: true))
        let echoed = VaultAnswer.reply(job: 33, status: 200, kept: Self.bytes("Bearer " + Self.key), total: 31, forms: forms)
        #expect(try wire(echoed) == #"{"job":33,"ok":true,"status":200,"v":2,"withheld":"key"}"#)
        #expect(Self.answer(of: echoed, job: 33) == .withheld("key"))
        let binary = VaultAnswer.reply(job: 34, status: 404, kept: Data([0xff, 0xfe, 0x00, 0x01]), total: 4, forms: forms)
        #expect(try wire(binary) == #"{"job":34,"ok":true,"status":404,"v":2,"withheld":"binary"}"#)
        #expect(Self.answer(of: binary, job: 34, status: 404) == .withheld("binary"))
    }

    // MARK: A body with a value

    @Test func aBodyWithAValueAsItIsIsNotShown() throws {
        // A password with a quote and a slash, a TOTP value with its seed, and a Basic request.
        let password = #"???SYN"THETIC/KEY"#, uri = "otpauth://totp/Test?secret=gezdgnbv%20gy3tqojq-gezdgnbvgy3tqojq%3D"
        let forms = VaultAnswer.forms(of: try Self.login(password, totp: uri), basic: Self.basic(password))
        #expect(forms.map { String(decoding: $0, as: UTF8.self) } == [password, uri, Self.seed, "YXBpLXVzZXI6Pz8/U1lOIlRIRVRJQy9LRVk="])
        let other = VaultAnswer.forms(of: try Self.login())
        for form in forms {
            #expect(Self.answer(form, forms) == .withheld("key"))
            #expect(Self.answer(Self.bytes("Authorization: Bearer ") + form + Self.bytes("\r\n"), forms) == .withheld("key"))
            // The same body for a login with another value is shown.
            #expect(Self.answer(Self.bytes("echo: ") + form, other) == .text("echo: " + String(decoding: form, as: UTF8.self), truncated: false))
        }
        // A Basic value is a form only for the request that sent it.
        let token = Self.bytes(Self.basic(Self.key))
        #expect(Self.answer(Self.bytes("Basic ") + token, VaultAnswer.forms(of: try Self.login(), basic: Self.basic(Self.key))) == .withheld("key"))
        #expect(Self.answer(Self.bytes("Basic ") + token, other) == .text("Basic " + Self.basic(Self.key), truncated: false))
    }

    @Test func aJSONAnswerThatGivesACharacterOfTheValueAsAnEscapeIsNotShown() throws {
        // The case of the reviewer: Python writes each character that is not ASCII as `\uXXXX`.
        let forms = VaultAnswer.forms(of: try Self.login("stand-in-\u{e9}-value-0123456789"))
        let other = VaultAnswer.forms(of: try Self.login())
        for echoed in [#"{"echo": "stand-in-\u00e9-value-0123456789"}"#, #"{"echo": "stand-in-\u00E9-value-0123456789"}"#,
                       #"{"echo": "stand\u002din\u002D\u00e9-value-0123456789"}"#] {
            #expect(Self.answer(Self.bytes(echoed), forms) == .withheld("key"))
            #expect(Self.answer(Self.bytes(echoed), other) == .text(echoed, truncated: false))
        }
        // A slash as `\/` and as `\u002f`, and a quote as `\"` and as `\u0022`.
        let marks = VaultAnswer.forms(of: try Self.login(#"SYN"THETIC/KEY-01"#))
        for echoed in [#"SYN\"THETIC\/KEY-01"#, #"SYN\"THETIC/KEY-01"#, #"SYN\u0022THETIC\u002fKEY-01"#, #"SYN\u0022THETIC\u002FKEY-01"#,
                       #"SYN\"THETIC\u002fKEY-01"#, #"SYN\u0022THETIC\/KEY-01"#, #"SYN"THETIC/KEY-01"#] {
            #expect(Self.answer(Self.bytes(#"{"authorization":"Bearer "# + echoed + #""}"#), marks) == .withheld("key"))
        }
        // A character outside the BMP as a pair of surrogates, in the two cases of the digits.
        let face = VaultAnswer.forms(of: try Self.login("key-\u{1f600}-0123456789"))
        for echoed in [#"key-\ud83d\ude00-0123456789"#, #"key-\uD83D\uDE00-0123456789"#, #"key-\ud83D\uDe00-0123456789"#, "key-\u{1f600}-0123456789"] {
            #expect(Self.answer(Self.bytes(#"["# + echoed + #"]"#), face) == .withheld("key"))
        }
        // Each surrogate alone is not that character.
        #expect(Self.answer(Self.bytes(#"key-\ud83d-\ude00-0123456789"#), face) == .text(#"key-\ud83d-\ude00-0123456789"#, truncated: false))
        // The Basic value: `/` and `=` as some JSON writers give them.
        let basic = VaultAnswer.forms(of: try Self.login("???SYNTHETIC-KEY"), basic: Self.basic("???SYNTHETIC-KEY"))
        #expect(basic.last == Self.bytes("YXBpLXVzZXI6Pz8/U1lOVEhFVElDLUtFWQ=="))
        for echoed in [#"YXBpLXVzZXI6Pz8\/U1lOVEhFVElDLUtFWQ=="#, #"YXBpLXVzZXI6Pz8/U1lOVEhFVElDLUtFWQ\u003d\u003d"#, #"YXBpLXVzZXI6Pz8\u002fU1lOVEhFVElDLUtFWQ=="#] {
            #expect(Self.answer(Self.bytes(#"{"Authorization":"Basic "# + echoed + #""}"#), basic) == .withheld("key"))
        }
    }

    @Test func everyJSONFormOfAValueIsFoundAndAnotherLoginGetsTheSameBody() throws {
        let other = VaultAnswer.forms(of: try Self.login("ANOTHER-SYNTHETIC-KEY-987654"))
        for value in Self.odd + [Self.key] {
            let forms = VaultAnswer.forms(of: try Self.login(value))
            for coding in Self.codings(of: value) {
                #expect(VaultAnswer.unescaped(coding).text == Self.bytes(value))
                let body = Self.bytes(#"{"headers":{"x-api-key":""#) + coding + Self.bytes(#""}}"#)
                #expect(Self.answer(body, forms) == .withheld("key"))
                #expect(Self.answer(body, other) == .text(String(decoding: body, as: UTF8.self), truncated: false))
            }
            // The value as it is, in an answer that is not JSON.
            #expect(Self.answer(Self.bytes("key: ") + Self.bytes(value), forms) == .withheld("key"))
        }
        // Escapes of two levels are not resolved: this is the known limit.
        let twice = Self.json(String(decoding: Self.json(Self.key), as: UTF8.self)) { _, _ in false }
        #expect(String(decoding: twice.prefix(14), as: UTF8.self) == #"\\u0053\\u0059"#)
        #expect(Self.answer(twice, VaultAnswer.forms(of: try Self.login())) == .text(String(decoding: twice, as: UTF8.self), truncated: false))
    }

    @Test func aValueAcrossTheCutIsNeverShownInPart() throws {
        let form = Self.bytes(Self.key), forms = VaultAnswer.forms(of: try Self.login())
        #expect(forms == [form])
        #expect(form.count == 24 && VaultAnswer.keep(for: forms) == 65_679)
        let shown = Answer.text(Self.text(65_536), truncated: true), withheld = Answer.withheld("key")
        // The value is at the start, and it is all of a body.
        #expect(Self.answer(Self.body(form, at: 0), forms) == withheld)
        #expect(Self.answer(form, forms) == withheld)
        // It ends exactly at the cut: bytes 65,512 to 65,535. All of it is in the part that can be shown.
        #expect(Self.answer(Self.body(form, at: 65_512), forms) == withheld)
        #expect(Self.answer(Self.body(form, at: 65_512, count: 65_536), forms) == withheld)
        // It ends one byte after the cut.
        #expect(Self.answer(Self.body(form, at: 65_513), forms) == withheld)
        // It begins one byte before the cut: only its first byte is in the part that can be shown.
        #expect(Self.answer(Self.body(form, at: 65_535), forms) == withheld)
        #expect(Self.answer(Self.body(form, at: 65_535, count: 65_559), forms) == withheld)
        // It begins exactly at the cut. No byte of it is in the part that is shown.
        #expect(Self.answer(Self.body(form, at: 65_536), forms) == shown)
        // It begins at the last byte that the vault keeps.
        #expect(Self.answer(Self.body(form, at: 65_678), forms) == shown)
        // It is completely after what the vault keeps.
        #expect(Self.answer(Self.body(form, at: 65_679), forms) == shown)
        #expect(Self.answer(Self.body(form, at: 99_976), forms) == shown)
    }

    @Test func anEscapedValueAcrossTheCutIsNeverShownInPart() throws {
        let forms = VaultAnswer.forms(of: try Self.login())
        // Each of the 24 characters as `\uXXXX`: 144 bytes, the longest form of this value.
        let longest = Self.json(Self.key)
        #expect(longest.count == 144 && VaultAnswer.keep(for: forms) == 65_679)
        let shown = Answer.text(Self.text(65_536), truncated: true), withheld = Answer.withheld("key")
        // It ends exactly at the cut.
        #expect(Self.answer(Self.body(longest, at: 65_392), forms) == withheld)
        // It begins some bytes before the cut and ends after it.
        #expect(Self.answer(Self.body(longest, at: 65_500), forms) == withheld)
        // It begins one byte before the cut: its first `\` is the last byte that can be shown, and its last byte is the
        // last byte that the vault keeps (65,678). One byte less in what is kept would not have all of it.
        #expect(Self.answer(Self.body(longest, at: 65_535), forms) == withheld)
        #expect(Self.answer(Self.body(longest, at: 65_535, count: 65_679), forms) == withheld)
        // It begins exactly at the cut: no byte of it is shown.
        #expect(Self.answer(Self.body(longest, at: 65_536), forms) == shown)
        // It begins at the last byte that the vault keeps, and it is completely after what the vault keeps.
        #expect(Self.answer(Self.body(longest, at: 65_678), forms) == shown)
        #expect(Self.answer(Self.body(longest, at: 65_679), forms) == shown)
        #expect(Self.answer(Self.body(longest, at: 90_000), forms) == shown)
        // A mix of escaped and plain characters across the cut, and an escape that the cut divides.
        let mixed = Self.bytes(#"SYNTHETIC\u002dKEY\u002D0123456789"#)
        #expect(Self.answer(Self.body(mixed, at: 65_520), forms) == withheld)
        #expect(Self.answer(Self.body(mixed, at: 65_524), forms) == withheld)
        #expect(Self.answer(Self.body(mixed, at: 65_536), forms) == shown)
    }

    @Test func aBodyIsWithheldExactlyWhenAValueBeginsBeforeTheCut() throws {
        // Values of 17, 32 and 36 bytes, each in each of its JSON forms, at the places near the cut and near the end
        // of what the vault keeps. The rule is the same for each: the length of a value does not change the reply.
        let password = #"???SYN"THETIC/KEY"#
        let forms = VaultAnswer.forms(of: try Self.login(password, totp: Self.seed), basic: Self.basic(password))
        #expect(forms.map(\.count) == [17, 32, 36])
        let keep = VaultAnswer.keep(for: forms)
        #expect(keep == 65_751)
        var wrong: [String] = [], checked = 0
        for form in forms {
            let value = String(decoding: form, as: UTF8.self)
            for coding in Set(Self.codings(of: value) + [form]) {
                let size = coding.count
                for place in Set([Self.cut - size - 1, Self.cut - size, Self.cut - 1, Self.cut, Self.cut + 1, keep - size, keep - 1, keep, keep + 1]) {
                    let expected = place < Self.cut ? Answer.withheld("key") : .text(Self.text(65_536), truncated: true)
                    checked += 1
                    if Self.answer(Self.body(coding, at: place, count: keep + size + 2), forms) != expected {
                        wrong.append("\(String(decoding: coding, as: UTF8.self)) at \(place)")
                    }
                }
            }
        }
        #expect(wrong.isEmpty && checked > 100)
    }

    @Test func aBodyThatEndsInsideAValueDoesNotHaveTheValue() throws {
        // Only a whole value is a value. The service sent 23 of the 24 bytes, and the first of them is before the cut.
        let forms = VaultAnswer.forms(of: try Self.login())
        let part = Self.letters(65_535) + Self.bytes(Self.key).dropLast()
        #expect(Self.answer(part, forms) == .text(Self.text(65_535) + "S", truncated: true))
    }

    @Test func aPartThatIsCutTooEarlyNeverShowsTheBytesThatCanBeginAValue() throws {
        let form = Self.bytes(Self.key), forms = [form]
        // The vault has only 65,536 bytes of a longer body, and the value begins at the last of them. The last 143
        // bytes are not shown: a value of 24 bytes that begins in them can end after what the vault has.
        let body = Self.body(form, at: 65_535)
        let short = VaultAnswer.reply(job: 7, status: 200, kept: Data(body.prefix(65_536)), total: body.count, forms: forms)
        #expect(Self.answer(of: short) == .text(Self.text(65_393), truncated: true))
        let small = VaultAnswer.reply(job: 7, status: 200, kept: Self.letters(200), total: 1_000, forms: forms)
        #expect(Self.answer(of: small) == .text(Self.text(57), truncated: true))
        let less = VaultAnswer.reply(job: 7, status: 200, kept: Self.letters(30), total: 100, forms: forms)
        #expect(Self.answer(of: less) == .text("", truncated: true))
        // Without a protected value there is nothing to wait for.
        let free = VaultAnswer.reply(job: 7, status: 200, kept: Self.letters(10), total: 100, forms: [])
        #expect(Self.answer(of: free) == .text(Self.text(10), truncated: true))
        // More than `keep(for:)` bytes change nothing.
        let more = VaultAnswer.reply(job: 7, status: 200, kept: body, total: body.count, forms: forms)
        #expect(Self.answer(of: more) == .withheld("key"))
        let late = Self.body(form, at: 65_536)
        #expect(Self.answer(of: VaultAnswer.reply(job: 7, status: 200, kept: late, total: late.count, forms: forms)) == .text(Self.text(65_536), truncated: true))
    }

    @Test func theEncodedReplyHasNoValueAlsoWhenTheBodyHasNone() throws {
        // The reply gives `/` as `\/`. This value has `\/` in it, so the reply of a body with `/` would have the value.
        let forms = VaultAnswer.forms(of: try Self.login(#"SYNTH\/ETIC\/KEY"#))
        let body = Self.bytes("SYNTH/ETIC/KEY")
        #expect(!forms.contains { body.range(of: $0) != nil || VaultAnswer.unescaped(body).text.range(of: $0) != nil })
        #expect(Self.answer(body, forms) == .withheld("key"))
        #expect(Self.answer(body, VaultAnswer.forms(of: try Self.login())) == .text("SYNTH/ETIC/KEY", truncated: false))
        // A value that is a word of the reply itself: no reply with a text is without it.
        #expect(Self.answer(Self.bytes("hello"), VaultAnswer.forms(of: try Self.login("truncated"))) == .withheld("key"))
    }

    @Test func aPartOfOtherDataIsReadByItsOwnBytes() {
        // The indexes of such data do not start at 0.
        let form = Self.bytes(Self.key)
        let echoed = (Data([0x00, 0xff, 0x80]) + Self.bytes("the key is " + Self.key))[3...]
        #expect(Self.answer(of: VaultAnswer.reply(job: 7, status: 200, kept: echoed, total: echoed.count, forms: [form])) == .withheld("key"))
        let escaped = (Data([0x5c, 0x75, 0x30]) + Self.bytes(#"the key is \u0053YNTHETIC-KEY-0123456789"#))[3...]
        #expect(Self.answer(of: VaultAnswer.reply(job: 7, status: 200, kept: escaped, total: escaped.count, forms: [form])) == .withheld("key"))
        let plain = (Data([0xff, 0xff]) + Self.bytes("caf\u{e9}"))[2...]
        #expect(Self.answer(of: VaultAnswer.reply(job: 7, status: 200, kept: plain, total: plain.count, forms: [form])) == .text("caf\u{e9}", truncated: false))
        let long = (form + Self.letters(65_535) + Self.bytes("\u{e9}") + Self.letters(200))[24...]
        #expect(Self.answer(of: VaultAnswer.reply(job: 7, status: 200, kept: long, total: long.count, forms: [form])) == .text(Self.text(65_535), truncated: true))
        let across = (Self.letters(5) + Self.body(form, at: 65_535))[5...]
        #expect(Self.answer(of: VaultAnswer.reply(job: 7, status: 200, kept: across.prefix(65_679), total: across.count, forms: [form])) == .withheld("key"))
        let after = (Self.letters(5) + Self.body(form, at: 65_536))[5...]
        #expect(Self.answer(of: VaultAnswer.reply(job: 7, status: 200, kept: after.prefix(65_679), total: after.count, forms: [form]))
                == .text(Self.text(65_536), truncated: true))
        #expect(VaultAnswer.status(in: Self.bytes("fleet 500\nfleet 200\n")[10...]) == 200)
        #expect(VaultAnswer.cutCharacter(in: Data([0xe2, 0x82, 0xac, 0xe2, 0x82])[3...]) == 2)
        #expect(VaultAnswer.unescaped(Self.bytes(#"xx\u0041b"#)[2...], split: 1).text == Self.bytes("Ab"))
    }

    // MARK: The escapes of an answer

    @Test func anEscapeThatIsCutOrNotValidStaysAsItIs() {
        func plain(_ text: String) -> String { String(decoding: VaultAnswer.unescaped(Self.bytes(text)).text, as: UTF8.self) }
        // Not complete, not hexadecimal, or not an escape of JSON.
        for same in [#""#, #"\"#, #"abc\"#, #"\u"#, #"\u0"#, #"\u00"#, #"\u00e"#, #"abc\u00e"#, #"\u00g9"#, #"\u00 9"#, #"\u+0e9"#, #"\u-0e9"#, #"\u0x41"#,
                     #"\U0041"#, #"\x41"#, #"\a"#, #"\'"#, #"\0"#, #"\ "#, #"\v"#, #"\N"#, "\\u\u{ff10}\u{ff10}e9", "\\\u{e9}"] {
            #expect(plain(same) == same)
        }
        // A surrogate without its other half, two halves in the wrong order, and a second half that is cut.
        for same in [#"\ud83d"#, #"\ude00"#, #"\ud83d \ude00"#, #"\ude00\ud83d"#, #"\ud83d\ud83d"#, #"\ud83d\ude0"#, #"\ud83d\ude0g"#, #"\ud83d\u"#, #"\ud83d\"#,
                     #"\udbff"#, #"\udc00"#, #"\udfff"#, #"\ud800"#] {
            #expect(plain(same) == same)
        }
        #expect(plain(#"\ud83d\u0041"#) == #"\ud83dA"#)
        #expect(plain(#"\ud83d\ud83d\ude00"#) == #"\ud83d"# + "\u{1f600}")
        #expect(plain(#"\ud83d\n"#) == #"\ud83d"# + "\n")
        // The escapes of two bytes, and escapes one after the other.
        #expect(plain(#"\"\\\/\b\f\n\r\t"#) == "\"\\/\u{8}\u{c}\n\r\t")
        #expect(plain(#"a\u0000b"#) == "a\u{0}b")
        #expect(plain(#""caf\u00e9 \u20ac \ud83d\ude00""#) == "\"caf\u{e9} \u{20ac} \u{1f600}\"")
        // One time only: an escaped `\` does not begin a new escape with the text after it.
        #expect(plain(#"\\u0041"#) == #"\u0041"#)
        #expect(plain(#"\\\u0041"#) == #"\A"#)
        #expect(plain(#"\\\\"#) == #"\\"#)
        #expect(plain(#"\u005cu0041"#) == #"\u0041"#)
        #expect(plain(#"\u005c\u005cn"#) == #"\\n"#)
        #expect(plain(#"\\n"#) == #"\n"#)
        // Bytes that are not text stay, also next to an escape.
        #expect(VaultAnswer.unescaped(Data([0xff, 0x5c, 0x6e, 0x80, 0x5c])).text == Data([0xff, 0x0a, 0x80, 0x5c]))
        #expect(VaultAnswer.unescaped(Data([0x5c, 0x75, 0x30, 0x30, 0xff, 0x39])).text == Data([0x5c, 0x75, 0x30, 0x30, 0xff, 0x39]))
        // A reply for such bodies is their text.
        for body in [#"\"#, #"abc\u00e"#, #"\ud83d"#, #"{"path":"C:\\new\\u0041", "half": "\ud83d"}"#] {
            #expect(Self.answer(Self.bytes(body), [Self.bytes(Self.key)]) == .text(body, truncated: false))
        }
    }

    @Test func everyCodeUnitEscapeGivesItsCharacterAndEveryPairOfSurrogatesGivesOne() {
        for uppercase in [false, true] {
            // Each code unit, with a `|` after it so that two halves do not come together.
            var given: [UInt8] = [], expected: [UInt8] = []
            for unit: UInt32 in 0...0xffff {
                let escape = Array(String(format: uppercase ? "\\u%04X|" : "\\u%04x|", unit).utf8)
                given += escape
                if let scalar = Unicode.Scalar(unit) { expected += Array(String(scalar).utf8) + [0x7c] } else { expected += escape }
            }
            #expect(VaultAnswer.unescaped(Data(given)).text == Data(expected))
            // Each first half with some second halves, and each second half with some first halves.
            given = []; expected = []
            func pair(_ high: UInt32, _ low: UInt32) {
                given += Array(String(format: uppercase ? "\\u%04X\\u%04X|" : "\\u%04x\\u%04x|", high, low).utf8)
                expected += Array(String(Unicode.Scalar(0x10000 + ((high - 0xd800) << 10) + (low - 0xdc00))!).utf8) + [0x7c]
            }
            for high: UInt32 in 0xd800...0xdbff { for low: UInt32 in [0xdc00, 0xdc01, 0xdd55, 0xdffe, 0xdfff] { pair(high, low) } }
            for low: UInt32 in 0xdc00...0xdfff { for high: UInt32 in [0xd800, 0xd801, 0xda2a, 0xdbfe, 0xdbff] { pair(high, low) } }
            #expect(VaultAnswer.unescaped(Data(given)).text == Data(expected))
        }
        #expect(VaultAnswer.unescaped(Self.bytes(#"\ud800\udc00\udbff\udfff"#)).text == Self.bytes("\u{10000}\u{10ffff}"))
    }

    @Test func theSplitOfAnAnswerIsTheSplitOfItsResolvedText() {
        // `ab`, one escape of six bytes, `cd`. The escape begins at byte 2: it is before a split at 3 or more.
        let given = Self.bytes(#"ab\u0041cd"#)
        #expect(VaultAnswer.unescaped(given).text == Self.bytes("abAcd"))
        #expect((0...11).map { VaultAnswer.unescaped(given, split: $0).split } == [0, 1, 2, 3, 3, 3, 3, 3, 3, 4, 5, 5])
        // A pair of surrogates is one sequence of twelve bytes.
        let pair = Self.bytes(#"a\ud83d\ude00b"#)
        #expect((0...14).map { VaultAnswer.unescaped(pair, split: $0).split } == [0, 1, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 6])
        // A sequence that is not an escape is its own bytes.
        let none = Self.bytes(#"a\u00"#)
        #expect((0...5).map { VaultAnswer.unescaped(none, split: $0).split } == [0, 1, 2, 3, 4, 5])
    }

    // MARK: Text

    @Test func aCutInsideOneCharacterDropsOnlyTheBytesOfThatCharacter() throws {
        let forms = VaultAnswer.forms(of: try Self.login())
        for (character, count) in [("\u{e9}", 2), ("\u{20ac}", 3), ("\u{1f600}", 4)] {
            #expect(character.utf8.count == count)
            // `held`: the count of bytes of one character that are before the cut. With all of them, or with none, the
            // cut is between two characters.
            for held in 0...count {
                let body = Self.letters(Self.cut - held) + Self.bytes(String(repeating: character, count: 10))
                let expected = Answer.text(held == count ? Self.text(Self.cut - count) + character : Self.text(Self.cut - held), truncated: true)
                #expect(Self.answer(body, []) == expected)
                #expect(Self.answer(body, forms) == expected)
            }
        }
        // The first and the last second byte that each first byte permits.
        for start: [UInt8] in [[0xc2], [0xdf], [0xe0], [0xe0, 0xa0], [0xe0, 0xbf], [0xed, 0x80], [0xed, 0x9f], [0xef, 0xbf], [0xf0], [0xf0, 0x90],
                               [0xf0, 0xbf, 0xbf], [0xf4], [0xf4, 0x80], [0xf4, 0x8f, 0xbf]] {
            let body = Self.letters(Self.cut - start.count) + Data(start) + Data(repeating: 0x80, count: 3)
            #expect(Self.answer(body, []) == .text(Self.text(Self.cut - start.count), truncated: true))
        }
        // 32,768 characters of two bytes after one letter: the last character before the cut has one byte there.
        let many = Self.bytes("a" + String(repeating: "\u{e9}", count: 40_000))
        #expect(Self.answer(many, forms) == .text("a" + String(repeating: "\u{e9}", count: 32_767), truncated: true))
    }

    @Test func bytesThatAreNotUTF8TextAreNotShown() {
        let binary = Answer.withheld("binary")
        // Bytes that are in no character, forms that are too long, a surrogate, a value above the last one, and a
        // character without its last bytes at the end of a body that is not cut.
        let bad: [[UInt8]] = [[0xff, 0xfe, 0x00, 0x01], [0x80], [0xbf], [0xc0, 0x80], [0xc1, 0xbf], [0xe0, 0x80, 0x80], [0xe0, 0x9f, 0xbf],
                              [0xed, 0xa0, 0x80], [0xed, 0xbf, 0xbf], [0xf0, 0x80, 0x80, 0x80], [0xf0, 0x8f, 0xbf, 0xbf], [0xf4, 0x90, 0x80, 0x80],
                              [0xf5, 0x80, 0x80, 0x80], [0xf8, 0x88, 0x80, 0x80, 0x80], [0xc3], [0xe2, 0x82], [0xf0, 0x9f, 0x98]]
        for bytes in bad {
            #expect(Self.answer(Data(bytes), []) == binary)
            #expect(Self.answer(Self.bytes("text ") + Data(bytes), []) == binary)
            #expect(Self.answer(Self.bytes("text ") + Data(bytes) + Self.bytes(" text"), []) == binary)
            #expect(Self.answer(Self.letters(70_000) + Data(bytes), []) == .text(Self.text(65_536), truncated: true))
        }
        // These are text: a NUL, a byte order mark, the last value of Unicode, and the first and last form of each length.
        for text in ["a\u{0}b", "\u{feff}a", "\u{10ffff}", "\u{80}\u{7ff}", "\u{800}\u{d7ff}\u{e000}\u{ffff}", "\u{10000}"] {
            #expect(Self.answer(Self.bytes(text), []) == .text(text, truncated: false))
        }
    }

    @Test func anInvalidByteInACutBodyIsNotTakenForACutCharacter() {
        let binary = Answer.withheld("binary")
        var middle = Self.letters(100_000)
        middle[30_000] = 0xff
        #expect(Self.answer(middle, []) == binary)
        // The last bytes before the cut. None of these can begin a character, so none of them is dropped.
        let tails: [[UInt8]] = [[0xff], [0xfe], [0x80], [0xbf], [0xc0], [0xc1], [0xf5], [0xf8], [0xff, 0x61], [0x80, 0x61, 0x61], [0xc3, 0xa9, 0x80],
                                [0x80, 0x80], [0xbf, 0xbf, 0xbf], [0xe0, 0x80], [0xe0, 0x9f], [0xed, 0xa0], [0xed, 0xbf], [0xf0, 0x80], [0xf0, 0x8f],
                                [0xf4, 0x90], [0xf4, 0xbf], [0xf0, 0x80, 0x80], [0xf4, 0x90, 0x80], [0xc2, 0xc2], [0xe2, 0xe2], [0xe2, 0x82, 0xe2, 0x41]]
        for tail in tails {
            let body = Self.letters(Self.cut - tail.count) + Data(tail) + Self.letters(1_000)
            #expect(Self.answer(body, []) == binary)
            #expect(Self.answer(body, [Self.bytes(Self.key)]) == binary)
        }
        // A cut character after an invalid byte does not make the body text.
        #expect(Self.answer(Self.letters(Self.cut - 3) + Data([0xff, 0xe2, 0x82, 0xac]), []) == binary)
        // The vault does not show a byte after the cut, and it does not judge it.
        var after = Self.letters(100_000)
        after[Self.cut] = 0xff
        #expect(Self.answer(after, []) == .text(Self.text(65_536), truncated: true))
    }

    @Test func theBytesOfACutCharacterAreExactlyTheBytesThatBeginAUnicodeCharacter() {
        // From each scalar value of Unicode: its UTF-8 form without its last byte, or last two or three bytes. A cut
        // inside a character leaves exactly such bytes.
        var one = [Bool](repeating: false, count: 1 << 8), two = [Bool](repeating: false, count: 1 << 16)
        var three = [Bool](repeating: false, count: 1 << 24), counts = [0, 0, 0]
        for value: UInt32 in 0...0x10ffff {
            guard let scalar = Unicode.Scalar(value), let encoded = Unicode.UTF8.encode(scalar) else { continue }
            let form = Array(encoded)
            if form.count > 1, !one[Int(form[0])] { one[Int(form[0])] = true; counts[0] += 1 }
            if form.count > 2, !two[Int(form[0]) << 8 | Int(form[1])] { two[Int(form[0]) << 8 | Int(form[1])] = true; counts[1] += 1 }
            if form.count > 3, !three[Int(form[0]) << 16 | Int(form[1]) << 8 | Int(form[2])] {
                three[Int(form[0]) << 16 | Int(form[1]) << 8 | Int(form[2])] = true; counts[2] += 1
            }
        }
        #expect(counts == [51, 1_216, 16_384])
        var wrong = 0, checked = 0
        var input = Data([0])
        for c in 0..<256 {
            input[0] = UInt8(c)
            checked += 1
            if VaultAnswer.cutCharacter(in: input) != (one[c] ? 1 : 0) { wrong += 1 }
        }
        input = Data([0, 0])
        for b in 0..<256 {
            input[0] = UInt8(b)
            for c in 0..<256 {
                input[1] = UInt8(c)
                checked += 1
                if VaultAnswer.cutCharacter(in: input) != (one[c] ? 1 : two[b << 8 | c] ? 2 : 0) { wrong += 1 }
            }
        }
        // Three bytes, alone and after one more byte, which must change nothing. Every first byte with every pair of
        // bytes 0x80...0xbf, and with every pair of the bytes at the limits of the ranges.
        let limits = [0x00, 0x41, 0x7f, 0x80, 0x8f, 0x90, 0x9f, 0xa0, 0xbf, 0xc0, 0xc1, 0xc2, 0xdf, 0xe0, 0xe1, 0xec, 0xed, 0xee, 0xef,
                      0xf0, 0xf1, 0xf3, 0xf4, 0xf5, 0xf7, 0xf8, 0xff]
        var alone = Data([0, 0, 0]), after = Data([0xf0, 0, 0, 0])
        func check(_ a: Int, _ b: Int, _ c: Int) {
            let expected = one[c] ? 1 : two[b << 8 | c] ? 2 : three[a << 16 | b << 8 | c] ? 3 : 0
            alone[0] = UInt8(a); alone[1] = UInt8(b); alone[2] = UInt8(c)
            after[1] = UInt8(a); after[2] = UInt8(b); after[3] = UInt8(c)
            checked += 2
            if VaultAnswer.cutCharacter(in: alone) != expected { wrong += 1 }
            if VaultAnswer.cutCharacter(in: after) != expected { wrong += 1 }
        }
        for a in 0..<256 {
            for b in 0x80...0xbf { for c in 0x80...0xbf { check(a, b, c) } }
            for b in limits { for c in limits { check(a, b, c) } }
        }
        #expect(wrong == 0)
        #expect(checked == 256 + 65_536 + 2 * 256 * (64 * 64 + 27 * 27))
        #expect(VaultAnswer.cutCharacter(in: Data()) == 0)
    }

    // MARK: The status line

    @Test func theStatusIsTheLastLineOfTheNoteExactlyAsCurlWritesIt() {
        func status(_ note: String) -> Int? { VaultAnswer.status(in: Self.bytes(note)) }
        #expect(status("fleet 200\n") == 200)
        #expect(status("fleet 404") == 404)
        #expect(status("fleet 100\n") == 100)
        #expect(status("fleet 599\n") == 599)
        // Other text before the last line is not read.
        #expect(status("Warning: an option of the config has no effect\nfleet 503\n") == 503)
        #expect(status("fleet 500\nfleet 201\n") == 201)
        #expect(status("fleet 000\r\nfleet 302\n") == 302)
        #expect(VaultAnswer.status(in: Data([0xff, 0xfe, 0x0a]) + Self.bytes("fleet 204\n")) == 204)
        // No status, a status outside 100...599, more or fewer than three digits, and other text in the last line.
        for note in ["fleet 000", "fleet 000\n", "fleet 099\n", "fleet 99", "fleet 99\n", "fleet 600", "fleet 600\n", "fleet 999\n", "fleet 2000",
                     "fleet 2000\n", "fleet 200 x", "fleet 200 x\n", "FLEET 200", "Fleet 200\n", "", "\n", "\n\n", "fleet", "fleet \n", "200\n",
                     " fleet 200\n", "fleet 200 \n", "fleet  200\n", "fleet\t200\n", "fleet200\n", "fleet 2 0\n", "fleet +20\n", "fleet -20\n",
                     "fleet 20\n", "fleet 2e2\n", "fleet 0x2\n", "fleet 200\r\n", "fleet 200\n\n", "fleet 200\nx", "fleet 200\nx\n", "fleet 200\n \n",
                     "xfleet 200\n", "fleet 200\u{0}\n", "fleet 20\u{0}\n", "fleet \u{662}\u{660}\u{660}\n", "fleet \u{ff12}\u{ff10}\u{ff10}\n",
                     "fleet 20\u{301}0\n", "curl: (28) Operation timed out\n"] {
            #expect(status(note) == nil, "\(note.debugDescription)")
        }
        // Bytes that are not text.
        for bytes: [UInt8] in [[0xff, 0xfe], [0xff], [0x00], [0x66, 0x6c, 0x65, 0x65, 0x74, 0x20, 0x32, 0x30, 0xff],
                               [0x66, 0x6c, 0x65, 0x65, 0x74, 0x20, 0x32, 0x30, 0x30, 0xff, 0x0a], [0x66, 0x6c, 0x65, 0x65, 0x74, 0xa0, 0x32, 0x30, 0x30]] {
            #expect(VaultAnswer.status(in: Data(bytes)) == nil)
        }
    }

    // MARK: Bounded work

    @Test func aLargeValueAndAHostileBodyDoNotMakeTheSearchLong() throws {
        let size = 65_536, length = 500_000
        func copies(_ block: Data, _ count: Int) -> Data {
            var all = Data()
            while all.count < count { all.append(block) }
            return Data(all.prefix(count))
        }
        // Values of 65,536 bytes: the vault keeps 458,751 bytes of an answer. In each body a value almost begins at
        // each byte. A search that compares a value from its start at each byte of a body needs more than
        // 25,000,000,000 steps for one of these.
        let a = Self.letters(size), b = Data([0x62]), z = Data([0x7a])
        let lastOther = a.dropLast() + b, firstOther = b + a.dropLast()
        let period = Data((0..<size).map { UInt8(0x61 + $0 % 7) }), slashes = copies(Self.bytes(#"\/"#), size)
        let forms = [lastOther, firstOther, period, slashes]
        #expect(forms.allSatisfy { $0.count == size } && VaultAnswer.keep(for: forms) == 458_751)
        // The bodies as they are, and bodies with an escape at each place: `\u0061` is `a`, and a surrogate alone stays.
        let bodies = [Self.letters(length), copies(lastOther.dropLast() + z, length), copies(firstOther.dropLast() + z, length),
                      copies(period.dropLast() + z, length), copies(slashes.dropLast() + Self.bytes(#"\"#), length),
                      copies(Self.bytes(#"\u0061"#), length), copies(Self.bytes(#"\ud83d"#), length), copies(Self.bytes(#"\\"#), length)]
        // The largest password that a login can have: 65,466 slashes.
        let login = try VaultLogin(data: Self.bytes(#"{"username":"api-user","password":""# + String(repeating: "/", count: 65_466)
                                                    + #"","url":"https://api.example.test"}"#), label: "Synthetic API")
        let large = VaultAnswer.forms(of: login)
        #expect(large.map(\.count) == [65_466] && VaultAnswer.keep(for: large) == 458_331)
        let near = copies(copies(Self.bytes(#"\/"#), 2 * 65_465) + z, length)
        let most = Data(repeating: 0x78, count: 65_535)
        var answers: [Answer] = []
        let elapsed = ContinuousClock().measure {
            for body in bodies { answers.append(Self.answer(body, forms)) }
            // A value of 65,536 bytes with each byte as `\uXXXX`: 393,216 bytes. It begins one byte before the cut, and
            // its last byte is the last byte that the vault keeps. One byte later, no byte of it is shown.
            answers.append(Self.answer(most + copies(Self.bytes(#"\u0061"#), 6 * size), [a]))
            answers.append(Self.answer(most + Data([0x78]) + copies(Self.bytes(#"\u0061"#), 6 * size), [a]))
            // The same for the largest password, and a body in which it almost begins at each `\/`.
            answers.append(Self.answer(most + copies(Self.bytes(#"\u002f"#), 6 * 65_466), large))
            answers.append(Self.answer(near, large))
        }
        #expect(answers.count == 12)
        for (answer, body) in zip(answers.prefix(8), bodies) {
            #expect(answer == .text(String(decoding: body.prefix(65_536), as: UTF8.self), truncated: true))
        }
        #expect(answers[8] == .withheld("key"))
        #expect(answers[9] == .text(String(repeating: "x", count: 65_536), truncated: true))
        #expect(answers[10] == .withheld("key"))
        #expect(answers[11] == .text(String(decoding: near.prefix(65_536), as: UTF8.self), truncated: true))
        // A search of the simple kind takes minutes for this. The limit is far above the time of this machine.
        #expect(elapsed < .seconds(10), "the replies took \(elapsed)")
    }
}
