import Foundation

/// What looks like a key in a text that the owner is about to put into a chat (owner feature `secret_requests`). The
/// hub masks only the values that it already knows, so a key that he pastes into a message is in the agent's
/// conversation, its runtime's own transcript and the hub's records before anything can mask it. The app asks
/// before such a paste and before such a send, and offers the secure form in its place.
///
/// It looks for two things: the shapes of the keys that the common services issue (each with its own prefix, so a
/// match is all but certain), and a long unbroken run of letters and digits in both cases that reads as random. It
/// is a guard and not a filter: the owner can always go on, and a text that it misses is no worse than before.
public enum KeyInText {
    /// The keys with a shape of their own. A private key matches from its first line to its last.
    private static let shapes: [NSRegularExpression] = [
        #"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----(?:[\s\S]{0,20000}?-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----)?"#,
        #"\bsk-(?:ant-[a-z0-9]+-|proj-|svcacct-|admin-|or-v1-)?[A-Za-z0-9_-]{20,}"#,     // Anthropic, OpenAI, OpenRouter
        #"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#, #"\bwhsec_[A-Za-z0-9]{20,}"#,          // Stripe
        #"\bgh[pousr]_[A-Za-z0-9]{30,}"#, #"\bgithub_pat_[A-Za-z0-9_]{40,}"#, #"\bglpat-[A-Za-z0-9_-]{20,}"#,
        #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#, #"\bxapp-[A-Za-z0-9-]{10,}"#,                     // Slack
        #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, #"\bAIza[0-9A-Za-z_-]{35}"#,                          // AWS, Google
        #"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#,                                       // SendGrid
        #"\b(?:hf|gsk|r8|npm|xai|pplx|tvly|lin_api|shpat|shpss|dop_v1)_[A-Za-z0-9_-]{20,}"#,
        #"\b(?:xai|pplx)-[A-Za-z0-9]{30,}"#,
        #"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,                    // a signed token
    ].map { try! NSRegularExpression(pattern: $0) }

    /// A run that can be a key with no shape of its own: base64 and URL-safe letters, at least 32 of them.
    private static let run = try! NSRegularExpression(pattern: #"[A-Za-z0-9+/=_-]{32,4096}"#)

    /// The first part of `text` that looks like a key, or nil.
    public static func first(in text: String) -> Range<String.Index>? {
        let whole = NSRange(text.startIndex..., in: text)
        var found: NSRange?
        for shape in shapes {
            if let match = shape.firstMatch(in: text, range: whole), found.map({ match.range.location < $0.location }) ?? true {
                found = match.range
            }
        }
        let words = text as NSString
        var read = Words(words)
        // A run comes first only when it ends before the key with a shape begins: a run that holds that key is no
        // better a guess at it, and `NAME=sk-…` is the key and not its name.
        for match in run.matches(in: text, range: whole) where found.map({ NSMaxRange(match.range) <= $0.location }) ?? true {
            let value = assigned(match.range, of: words)
            if value.length >= 32, !read.inPicture(value), !read.inAddressPath(value.location),
               looksRandom(words.substring(with: value)) { found = value; break }
        }
        return found.flatMap { Range($0, in: text) }
    }

    /// The part of a run after its last `=` that is not base64's padding: the value of `NAME=value`, or the run.
    static func assigned(_ range: NSRange, of text: NSString) -> NSRange {
        let run = text.substring(with: range)
        let body = run.replacingOccurrences(of: "=+$", with: "", options: .regularExpression)
        guard let sign = body.range(of: "=", options: .backwards) else { return range }
        let skip = body[..<sign.upperBound].utf16.count
        return NSRange(location: range.location + skip, length: range.length - skip)
    }

    /// **The words of a text, read once from its first unit to its last** (24 November 2026). Each run read its word
    /// back to the space before it, so a long word, such as a picture's data in a Markdown file, took seconds for a
    /// megabyte. A word reaches from the last whitespace (Apple's `whitespacesAndNewlines`, which holds U+200B) or half
    /// of a pair before a place, as a run's word was read; each place asked for is at or after the one before.
    struct Words {
        private let text: NSString
        /// The units read: up to here.
        private var at = 0
        /// The first unit of the word that the next unread unit stands in.
        private(set) var start = 0
        /// Of the word that begins at `word`: the end of its first `://`, and the place of the first `?` or `#` after
        /// it, as the words before a run were searched; found once for the whole word (`facts`).
        private var word = -1, scheme: Int?, query: Int?
        /// The part of a picture's address that `at` stands in (`read`): its media type after "data:image/" (`type`),
        /// or its base64 after ";base64," (`data`).
        private enum Picture { case none, type, data }
        private var picture = Picture.none
        private static let imageMark = Array("data:image/".utf16), base64Mark = Array(";base64,".utf16)
        /// The whitespace among the first 128 units, as Apple's set has it; base64's letters, without its "="; and the
        /// units of a media type and its parameters (`image/svg+xml;charset=utf-8`).
        private static let spaces: [Bool] = (0..<128).map { CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(UInt8($0))) }
        private static let letters: [Bool] = (0..<128).map { unit in
            let character = Character(Unicode.Scalar(UInt8(unit)))
            return character.isLetter || character.isNumber || "+/".contains(character)
        }
        private static let types: [Bool] = (0..<128).map { unit in
            let character = Character(Unicode.Scalar(UInt8(unit)))
            return character.isLetter || character.isNumber || ".+-_;=%".contains(character)
        }

        init(_ text: NSString) { self.text = text }

        /// **Whether a run stands in the base64 of a picture's `data:` address** (in a Markdown or HTML file:
        /// `![logo](data:image/png;base64,…)`), whose letters read as random and are no key. All of this, in one word:
        ///
        /// 1. "data:image/", then ";base64,", and between them only the units of a media type and its parameters:
        ///    A-Z, a-z, 0-9 and `. + - _ ; = %`;
        /// 2. from just after ";base64," to the run, only base64's letters: A-Z, a-z, 0-9, "+" and "/";
        /// 3. the run itself is base64: those letters, and "=" only at its end.
        ///
        /// Any other unit ends the picture for good, "=" too: a later ";base64," of the word opens nothing until another
        /// "data:image/" (25 November 2026: `…=","k":"x;base64,RUN` and `…=token=RUN` were let through). So a comma, a
        /// quote, a bracket or a colon before ";base64,", and a run right after the "=" of a picture, are read as any
        /// text, as is a `data:` address of another kind. A picture longer than one run (4,096 letters) stays a picture
        /// in each of its runs. A key with a shape of its own is found there all the same. The same rule in each port of
        /// `app/vectors/key-in-text.json`.
        ///
        /// - What it still lets through: a random run, and a key whose shape needs a word boundary at its start or its
        ///   end (AWS, Google, SendGrid), that is base64 letters and touches a picture's letters with no mark between: it
        ///   reads as more of the picture, at any length (the rule before 24 November 2026 held it from 32 letters). So a
        ///   key that is the whole of a picture's data (`data:image/png;base64,<key>`), a key at the start of the data
        ///   with letters of the picture after it, and a key joined to them with "+" or "/", which are base64's letters
        ///   too. After "=", a quote, a bracket or a space every key is found again, and a run with "-" or "_" in it is
        ///   no base64 (3).
        /// - What it holds that is no key, by choice: a picture whose base64 a "-" or "_" follows with no mark between,
        ///   as the end of an HTML comment (`data:image/png;base64,…-->`): the run holds them, so it is no base64 (3).
        ///   He can keep it with "Keep it".
        mutating func inPicture(_ run: NSRange) -> Bool {
            read(to: run.location)
            guard picture == .data else { return false }
            // a run's value holds "=" only at its end (`assigned`); this holds the rule also for a caller that does not
            var padding = false
            for index in run.location..<NSMaxRange(run) {
                let unit = text.character(at: index)
                if unit == 0x3D { padding = true } else if padding || !Self.isOne(unit, of: Self.letters) { return false }
            }
            return true
        }

        /// **Whether a run that begins at `location` stands in the path of a web address**, where the id of a document, a
        /// file or a commit reads as random and is no key: after the word's first `://` and before its query or fragment
        /// (`?` or `#`). A run in a query (`?key=…`) is looked at, and a key with a shape of its own is found anywhere.
        /// The word's `://` and its `?` or `#` are found once for all its runs (round 2 of 24 November 2026: each run
        /// copied and searched its word up to itself, so a line of thousands of hashes or ids took minutes); a find
        /// before the run's start is a find of the words before it, because whether it counts reads only the unit after
        /// it (`stands`).
        mutating func inAddressPath(_ location: Int) -> Bool {
            read(to: location)
            if word != start { facts() }
            guard let scheme, scheme <= location else { return false }
            return query.map { $0 >= location } ?? true
        }

        /// The word's first `://` that counts, and the first `?` or `#` that counts after it (`stands`): read once from
        /// the word's start to its end, as the hub's port reads them (`key_word_facts`).
        private mutating func facts() {
            word = start; scheme = nil; query = nil
            var end = start
            while end < text.length, !Self.stops(text.character(at: end)) { end += 1 }
            var index = start
            while index + 3 <= end {
                if text.character(at: index) == 0x3A, text.character(at: index + 1) == 0x2F,
                   text.character(at: index + 2) == 0x2F, stands(index + 3, end) { scheme = index + 3; break }
                index += 1
            }
            guard var mark = scheme else { return }
            while mark < end {
                let unit = text.character(at: mark)
                if unit == 0x3F || unit == 0x23, stands(mark + 1, end) { query = mark; return }
                mark += 1
            }
        }

        /// **Whether a find that ends before unit `at` counts**: not when that unit is a character of Unicode's
        /// Grapheme_Extend, which joins the find's last character, as Foundation's search read the words before a run,
        /// whatever came after them. Grapheme_Extend is every non-spacing and enclosing mark (Mn, Me), U+200C, and 34
        /// spacing marks of the BMP (Unicode 16): U+09BE, 09D7, 0B3E, 0B57, 0BBE, 0BD7, 0CC0, 0CC2, 0CC7, 0CC8, 0CCA,
        /// 0CCB, 0CD5, 0CD6, 0D3E, 0D57, 0DCF, 0DDF, 1715, 1734, 1B35, 1B3B, 1B3D, 1B43, 1B44, 1BAA, 1BF2, 1BF3, 302E,
        /// 302F, A953, A9C0, FF9E and FF9F (25 November 2026: "https://" and U+FF9E made an address of the words after
        /// it, which Foundation's search did not). Half of a pair stands. The same in the hub's and the Windows app's
        /// ports (`key_stands`, `Stands`), which hold the whole list as `app/vectors/key-in-text.json`'s
        /// `tables.address_marks` gives it, measured from Foundation's search on the Mac that wrote it.
        private func stands(_ at: Int, _ end: Int) -> Bool {
            guard at < end else { return true }
            let unit = text.character(at: at)
            if unit == 0x200C || Self.joiners.contains(unit) { return false }
            guard let scalar = Unicode.Scalar(unit) else { return true }
            let category = scalar.properties.generalCategory
            return category != .nonspacingMark && category != .enclosingMark
        }

        /// The joiners that are no Mn or Me in every Unicode data that the Mac reads, written out: the spacing marks of
        /// Grapheme_Extend in the BMP (Unicode 16; Apple's Grapheme_Extend also counts some characters of private use,
        /// which Foundation's search does not), and the non-spacing marks of the BMP newer than Unicode 15 (U+0897,
        /// U+1ACF-1ADD, U+1AE0-1AEB), which an older system reads as unassigned (the readers, 25 November 2026).
        private static let joiners: Set<unichar> = [
            0x0897, 0x1ACF, 0x1AD0, 0x1AD1, 0x1AD2, 0x1AD3, 0x1AD4, 0x1AD5, 0x1AD6, 0x1AD7, 0x1AD8, 0x1AD9, 0x1ADA, 0x1ADB,
            0x1ADC, 0x1ADD, 0x1AE0, 0x1AE1, 0x1AE2, 0x1AE3, 0x1AE4, 0x1AE5, 0x1AE6, 0x1AE7, 0x1AE8, 0x1AE9, 0x1AEA, 0x1AEB,
            0x09BE, 0x09D7, 0x0B3E, 0x0B57, 0x0BBE, 0x0BD7, 0x0CC0, 0x0CC2, 0x0CC7, 0x0CC8, 0x0CCA, 0x0CCB, 0x0CD5, 0x0CD6,
            0x0D3E, 0x0D57, 0x0DCF, 0x0DDF, 0x1715, 0x1734, 0x1B35, 0x1B3B, 0x1B3D, 0x1B43, 0x1B44, 0x1BAA, 0x1BF2, 0x1BF3,
            0x302E, 0x302F, 0xA953, 0xA9C0, 0xFF9E, 0xFF9F]

        /// Reads up to `location`, where the run begins; `start` is then its word's first unit.
        mutating func read(to location: Int) {
            while at < location {
                let unit = text.character(at: at)
                if Self.stops(unit) {
                    start = at + 1; picture = .none
                } else {
                    switch picture {
                    case .none:
                        break
                    case .type:
                        // ";base64," cannot reach back into "data:image/", which holds no ";"
                        if ends(at, with: Self.base64Mark) {
                            picture = .data
                        } else if !Self.isOne(unit, of: Self.types) {
                            picture = .none
                        }
                    case .data:
                        // "=" ends the base64 too: what follows it is no picture
                        if !Self.isOne(unit, of: Self.letters) { picture = .none }
                    }
                    // the ":" of "data:image/" ended any picture before it, so this begins a picture of its own
                    if picture == .none, ends(at, with: Self.imageMark) { picture = .type }
                }
                at += 1
            }
        }

        /// `unit` is one of the first 128 units that `marks` holds.
        private static func isOne(_ unit: unichar, of marks: [Bool]) -> Bool { unit < 128 && marks[Int(unit)] }

        /// A unit that ends a word: whitespace, or half of a pair, where the walk back from a run stopped.
        private static func stops(_ unit: unichar) -> Bool {
            if unit < 128 { return spaces[Int(unit)] }
            guard let scalar = Unicode.Scalar(unit) else { return true }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }

        /// The units up to `index` end with `mark`.
        private func ends(_ index: Int, with mark: [unichar]) -> Bool {
            guard index + 1 >= mark.count else { return false }
            let first = index + 1 - mark.count
            for (offset, unit) in mark.enumerated() where text.character(at: first + offset) != unit { return false }
            return true
        }
    }

    /// Whether `text` holds something that looks like a key.
    public static func contains(_ text: String) -> Bool { first(in: text) != nil }

    /// **A knowledge file's text as the hub saves it** (the hub's `knowledge_saved_text`): one "\n" for each line end
    /// ("\r\n" and "\r"), and a space for each other control character (U+0000-0008, U+000B-001F and U+007F-009F; a
    /// tab and "\n" stay). The knowledge page checks and keeps the parts of this form, as the hub checks it (25 November
    /// 2026, the Door area's reader): in the raw text a private key's lines can end in "\r\n", so the part that he kept
    /// was not the hub's, and U+001F joins words that the saved file parts, so the hub found a key that he was never
    /// asked about. `app/vectors/key-in-text.json`'s `saved` holds its cases for each port.
    public static func savedForm(_ text: String) -> String {
        var saved = String.UnicodeScalarView()
        var afterReturn = false
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if afterReturn, value == 0x0A { afterReturn = false; continue }      // "\r\n": the "\n" of its "\r"
            afterReturn = value == 0x0D
            if value == 0x0D {
                saved.append("\n")
            } else if value <= 0x08 || (0x0B...0x1F).contains(value) || (0x7F...0x9F).contains(value) {
                saved.append(" ")
            } else {
                saved.append(scalar)
            }
        }
        return String(saved)
    }

    /// **Every part of `text` that looks like a key**, in the order of the text, each where it stands in `text`: each
    /// key with a shape of its own, and each run that reads as random outside of them (`first(in:)` finds one). A
    /// knowledge file's box asks only about a part that the hub's text of the file does not hold already.
    public static func all(in text: String) -> [Substring] {
        let whole = NSRange(text.startIndex..., in: text)
        func overlaps(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
            ranges.contains { NSIntersectionRange($0, range).length > 0 }
        }
        var shaped: [NSRange] = []
        for shape in shapes {
            for match in shape.matches(in: text, range: whole) where !overlaps(match.range, shaped) { shaped.append(match.range) }
        }
        let words = text as NSString
        var found = shaped, read = Words(words)
        // A run that holds a key with a shape is that key, as in `first(in:)`; its value after `NAME=` is what counts.
        for match in run.matches(in: text, range: whole) {
            let value = assigned(match.range, of: words)
            if value.length >= 32, !overlaps(value, shaped), !read.inPicture(value),
               !read.inAddressPath(value.location), looksRandom(words.substring(with: value)) { found.append(value) }
        }
        return found.sorted { $0.location < $1.location }.compactMap { Range($0, in: text).map { text[$0] } }
    }

    /// A run that reads as random: capitals, small letters and digits all three, not a path, about as varied as
    /// random letters are, changing between them as often, and with few runs of small letters that read as words. A
    /// name in camel case, a hash in hex, a path and a UUID are none of these. Of random runs of 32 letters and
    /// digits, about 1 in 40 passes as not random; of longer ones, almost none.
    static func looksRandom(_ run: String) -> Bool {
        let scalars = Array(run.unicodeScalars)
        guard scalars.count >= 32, !run.hasPrefix("/"), !run.contains("//") else { return false }
        func kind(_ scalar: Unicode.Scalar) -> Int {
            ("A"..."Z").contains(scalar) ? 0 : ("a"..."z").contains(scalar) ? 1 : ("0"..."9").contains(scalar) ? 2 : 3
        }
        let kinds = scalars.map(kind)
        guard kinds.contains(0), kinds.contains(1), kinds.contains(2) else { return false }
        var counts: [Unicode.Scalar: Int] = [:]
        for scalar in scalars { counts[scalar, default: 0] += 1 }
        let total = Double(scalars.count)
        let entropy = counts.values.reduce(0.0) { sum, count in
            let share = Double(count) / total
            return sum - share * log2(share)
        }
        let changes = Double(zip(kinds, kinds.dropFirst()).filter { $0 != $1 }.count) / (total - 1)
        // The letters that stand in runs of four or more small letters: most of a name, little of a key.
        var wordy = 0, small = 0
        for kind in kinds + [0] {
            if kind == 1 { small += 1; continue }
            if small >= 4 { wordy += small }
            small = 0
        }
        return entropy >= 4.2 && changes >= 0.4 && Double(wordy) / total < 0.4
    }
}
