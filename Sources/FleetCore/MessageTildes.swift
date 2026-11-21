import Foundation

extension MessageBlock {
    /// The text with each single "~" escaped, so that Apple's parser strikes through only "~~words~~". Agents write "~"
    /// for "about" ("~13,600 listings ... ~$3,900"), and the parser read two single tildes as the ends of a struck-out
    /// part: the words between them went out with a line through them, and the tildes went (the owner, 20 November
    /// 2026: "why is the text like repeated and crossed out?!?"). A run of two or more stays, and so does each tilde
    /// that the parser reads as no mark (`TildeReader` says where), and a text with one mark alone stays as it is. Three
    /// known limits: a "~" in the punctuation that the parser cuts from the end of a bare web address
    /// ("https://example.com/~.") keeps no escape, because an escape there joins the address and breaks its link, so two
    /// such tildes still strike through what is between them when the first one stands between two punctuation marks;
    /// the parser reads past a "~" (but not past an escape) to see whether a "*" or "_" that touches it may open or
    /// close italics, so in a rare text such as "a*~b" an escape changes which of them make italics; and the reader
    /// does not know reference links: a "[label]: address" line at the start of a block, which the parser hides, and
    /// the "[words][label]" that uses it.
    public static func keepingTildes(_ text: String) -> String {
        guard text.unicodeScalars.contains("~") else { return text }      // a "~" with a combining mark is one Character
        var reader = TildeReader(text)
        return reader.escaped()
    }
}

/// Reads a text as Apple's parser reads it (`AttributedString(markdown:)` with `.inlineOnlyPreservingWhitespace`: the
/// whole text is one paragraph of swift-cmark, with GitHub's strikethrough and autolinks), as far as a "~" depends on
/// it. The rules are the ones that the parser of macOS gives, measured on 20 November 2026. A "~" is no mark:
/// - in a code span, after a backslash, and in an autolink or a piece of HTML after a "<", which the parser shows as it
///   is written: a comment's words may hold "--" but not end with "--->", and after a comment that fails no "<!" is
///   one; a declaration is "<!", capital letters and a space; a tag's spaces are ASCII ones;
/// - in the address and the title after the "](" of a link or a picture, and in the "(...)" after the "]" of "^[";
/// - in a bare web address that the parser links: at a ":" with "//" after "http", "https" or "ftp" (in any case, with
///   no letter before it, and after the "//" no space and no punctuation), or at a lowercase "www." at the text's start or
///   after a space, "*", "_", "~" or "(" (and then only with a dot in its domain); never inside a "[" or "!["; no
///   "_" in its domain's last two parts. The address ends at a space, a tab, a line end or a "<" (not at a no-break
///   space), less the punctuation that the parser cuts from its end.
struct TildeReader {
    private let text: String                // as an NSString's UTF-16, so that a regular expression reads it in place
    private let chars: [Unicode.Scalar]
    private let count: Int
    private let utf8: [Int]                 // where each scalar starts, in UTF-8 (the parser counts bytes), and the end
    private let utf16: [Int]                // the same in UTF-16, for the regular expressions
    private let lastTicks: [Int: Int]       // where the last run of n backticks starts
    private let lastClose: Int              // where the last ">" is
    private let closes: [Int: Int]          // for each "(" after the "]" of "^[", where its ")" is
    // as the parser does, a comment, a processing instruction or a CDATA part that fails once is not tried again
    private var noComment = false, noProcessing = false, noData = false

    init(_ given: String) {
        // the parser reads a NUL as U+FFFD, so the reader does too: the text that it draws is the same either way
        // (by scalars: a NUL with a combining mark after it is one Character)
        let text = !given.unicodeScalars.contains("\0") ? given
            : String(String.UnicodeScalarView(given.unicodeScalars.map { $0 == "\0" ? "\u{FFFD}" : $0 }))
        let units = Array(text.utf16)
        self.text = NSString(characters: units, length: units.count) as String
        chars = Array(text.unicodeScalars)
        count = chars.count
        var utf8 = [0], utf16 = [0], ticks: [Int: Int] = [:], close = -1, caret = false
        utf8.reserveCapacity(count + 1); utf16.reserveCapacity(count + 1)
        var i = 0
        while i < count {
            let c = chars[i]
            if c == ">" { close = i }
            if c == "[", i > 0, chars[i - 1] == "^" { caret = true }      // by scalars: a mark may sit on the "["
            if c == "`", i == 0 || chars[i - 1] != "`" {
                var n = 1
                while i + n < count, chars[i + n] == "`" { n += 1 }
                ticks[n] = i
            }
            utf8.append(utf8[i] + UTF8.width(c)); utf16.append(utf16[i] + UTF16.width(c))
            i += 1
        }
        self.utf8 = utf8; self.utf16 = utf16; lastTicks = ticks; lastClose = close
        closes = caret ? Self.parentheses(chars) : [:]
    }

    /// Where the ")" that closes each "(" is, with escapes, in one pass: the "(...)" of "^[" ends there.
    private static func parentheses(_ chars: [Unicode.Scalar]) -> [Int: Int] {
        var closes: [Int: Int] = [:], open: [Int] = [], j = 0
        while j < chars.count {
            let c = chars[j]
            if c == "\\", j + 1 < chars.count, punctuation(chars[j + 1]) { j += 2; continue }
            if c == "(" { open.append(j) } else if c == ")", let start = open.popLast() { closes[start] = j }
            j += 1
        }
        return closes
    }

    /// The text with a backslash before each single "~" that the parser reads as a mark.
    mutating func escaped() -> String {
        let chars = chars
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(count + count / 8)
        var i = 0
        var brackets: [(kind: Bracket, active: Bool)] = []  // the open "[", "![" and "^["
        var holding = 0                                     // how many of them are "[" or "![": no bare address inside
        var cut = 0..<0                                     // what the parser cut from the end of the last bare address
        var marks = 0                                       // the single tildes that the parser reads as marks
        func take(_ end: Int) { out.append(contentsOf: chars[i..<end]); i = end }
        while i < count {
            let c = chars[i]
            switch c {
            case "\\":
                take(i + 1 < count && Self.punctuation(chars[i + 1]) ? i + 2 : i + 1)
            case "`":
                take(codeSpanEnd(at: i))
            case "<":
                take(rawEnd(at: i) ?? i + 1)
            case "!" where i + 1 < count && chars[i + 1] == "[" && !(i + 2 < count && chars[i + 2] == "^"):
                brackets.append((kind: .image, active: true)); holding += 1; take(i + 2)
            case "^" where i + 1 < count && chars[i + 1] == "[":
                brackets.append((kind: .attributes, active: true)); take(i + 2)
            case "[":
                brackets.append((kind: .link, active: true)); holding += 1; take(i + 1)
            case "]":
                take(i + 1)
                guard let opener = brackets.popLast() else { break }
                if opener.kind == .attributes {
                    if let end = attributesEnd(at: i) { take(end) }
                    break
                }
                holding -= 1
                if opener.active, let end = linkTailEnd(at: i) {
                    if opener.kind == .link {               // no link inside a link
                        for k in brackets.indices where brackets[k].kind == .link { brackets[k].active = false }
                    }
                    take(end)
                }
            case ":" where holding == 0:
                if let link = urlLink(at: i) { take(link.end); cut = link.end..<link.stop } else { take(i + 1) }
            case "w" where holding == 0:
                if let link = wwwLink(at: i) { take(link.end); cut = link.end..<link.stop } else { take(i + 1) }
            case "~":
                var n = 1
                while i + n < count, chars[i + n] == "~" { n += 1 }
                // the parser reads 100 tildes at most as one run, so one or two left over after hundreds are a mark
                let left = n % 100
                guard left == 1 || left == 2 && n > 100 else { take(i + n); break }
                take(i + n - left)
                marks += left                   // two left over can pair with a "~~" elsewhere
                for _ in 0..<left {
                    if !cut.contains(i) { out.append("\\") }
                    take(i + 1)
                }
            default:
                take(i + 1)
            }
        }
        return marks < 2 ? text : String(String.UnicodeScalarView(out))     // one mark alone strikes nothing through
    }

    /// "[" opens a link's words, "![" a picture's, and "^[" Apple's attributes ("^[words](name: value)"), inside which
    /// the parser still links a bare address.
    private enum Bracket { case link, image, attributes }

    // MARK: Code, autolinks and HTML

    /// The end of the code span that starts at `i`, or of its backticks alone when no run of as many comes after them.
    private func codeSpanEnd(at i: Int) -> Int {
        var n = 1
        while i + n < count, chars[i + n] == "`" { n += 1 }
        guard let last = lastTicks[n], last > i else { return i + n }
        var j = i + n
        while j < count {
            guard chars[j] == "`" else { j += 1; continue }
            var m = 1
            while j + m < count, chars[j + m] == "`" { m += 1 }
            if m == n { return j + m }
            j += m
        }
        return i + n
    }

    /// The end of the autolink or the piece of HTML that starts at the "<" at `i`, which the parser keeps as written.
    private mutating func rawEnd(at i: Int) -> Int? {
        if let end = match(Self.uriAutolink, at: i) ?? emailEnd(at: i) { return end }
        guard i + 2 < count else { return nil }
        switch chars[i + 1] {
        case "!":
            guard !noComment else { return nil }               // after a comment that failed, no "<!" is tried
            if chars[i + 2] == "-" {
                guard i + 3 < count, chars[i + 3] == "-" else { return match(Self.declaration, at: i) }
                if i + 4 < count, chars[i + 4] == ">" { return i + 5 }                          // "<!-->"
                if i + 5 < count, chars[i + 4] == "-", chars[i + 5] == ">" { return i + 6 }     // "<!--->"
                if let end = markedEnd(from: i + 4, mark: "-", twice: true) { return end }
                noComment = true
                return nil
            }
            if chars[i + 2] == "[" {
                let open = Array("<![CDATA[".unicodeScalars)
                guard !noData, i + open.count <= count, Array(chars[i..<(i + open.count)]) == open else { return nil }
                if let end = markedEnd(from: i + open.count, mark: "]", twice: true) { return end }
                noData = true
                return nil
            }
            return lastClose > i ? match(Self.declaration, at: i) : nil
        case "?":
            guard !noProcessing else { return nil }
            if let end = markedEnd(from: i + 2, mark: "?", twice: false) { return end }
            noProcessing = true
            return nil
        default:
            return tagEnd(at: i)
        }
    }

    /// The end of an email autolink ("<name@example.com>") at the "<" at `i`: its name's characters, "@", and labels of 1
    /// to 63 letters, digits and hyphens that start and end with a letter or a digit, with dots between them.
    private func emailEnd(at i: Int) -> Int? {
        var j = i + 1
        while j < count, Self.emailName(chars[j]) { j += 1 }
        guard j > i + 1, j < count, chars[j] == "@" else { return nil }
        j += 1
        while true {
            let start = j
            while j < count, Self.alphanumeric(chars[j]) || chars[j] == "-" { j += 1 }
            guard j > start, j - start <= 63, Self.alphanumeric(chars[start]), Self.alphanumeric(chars[j - 1]),
                  j < count else { return nil }
            if chars[j] == ">" { return j + 1 }
            guard chars[j] == "." else { return nil }
            j += 1
        }
    }

    /// The end of an open or a closing tag at the "<" at `i`, as the parser's grammar reads it: a name, and attributes
    /// that each come after a space, with or without "=" and a value in quotes or with no space, quote, "=", "<", ">"
    /// or "`" in it. The same loop as `markedEnd`, for the same reason.
    private func tagEnd(at i: Int) -> Int? {
        var j = i + 1
        let closing = j < count && chars[j] == "/"
        if closing { j += 1 }
        guard j < count, Self.letter(chars[j]) else { return nil }
        j += 1
        while j < count, Self.alphanumeric(chars[j]) || chars[j] == "-" { j += 1 }
        if closing {
            while j < count, Self.spaceOfSyntax(chars[j]) { j += 1 }
            return j < count && chars[j] == ">" ? j + 1 : nil
        }
        while j < count {
            let spaced = j
            while j < count, Self.spaceOfSyntax(chars[j]) { j += 1 }
            guard j < count else { return nil }
            if chars[j] == ">" { return j + 1 }
            if chars[j] == "/" { return j + 1 < count && chars[j + 1] == ">" ? j + 2 : nil }
            guard j > spaced, Self.letter(chars[j]) || chars[j] == "_" || chars[j] == ":" else { return nil }
            j += 1
            while j < count, Self.alphanumeric(chars[j]) || "_.:-".unicodeScalars.contains(chars[j]) { j += 1 }
            var k = j
            while k < count, Self.spaceOfSyntax(chars[k]) { k += 1 }
            guard k < count, chars[k] == "=" else { continue }      // no value: the spaces go to what comes next
            k += 1
            while k < count, Self.spaceOfSyntax(chars[k]) { k += 1 }
            guard k < count else { return nil }
            if chars[k] == "\"" || chars[k] == "'" {
                let quote = chars[k]
                k += 1
                while k < count, chars[k] != quote, chars[k] != "\0" { k += 1 }
                guard k < count, chars[k] == quote else { return nil }
                j = k + 1
            } else {
                let start = k
                while k < count, !" \t\n\u{0B}\u{0C}\r\"'=<>`\0".unicodeScalars.contains(chars[k]) { k += 1 }
                guard k > start else { return nil }
                j = k
            }
        }
        return nil
    }

    /// Where a comment (read from after its "<!--"), a CDATA part (after "<![CDATA[") or a processing instruction (after
    /// "<?") ends, as the parser's grammar reads it: the end is the mark ("-", "]" or "?"), twice or once, and ">"; a
    /// mark that another character follows is words, and so is "--" or "]]" with no ">" after it. A loop and no regular
    /// expression: ICU gives up on a piece of about 500,000 characters.
    private func markedEnd(from start: Int, mark: Unicode.Scalar, twice: Bool) -> Int? {
        var j = start
        while j < count {
            let c = chars[j]
            if c == "\0" { return nil }
            guard c == mark else { j += 1; continue }
            guard j + 1 < count, chars[j + 1] != "\0" else { return nil }
            if !twice {
                if chars[j + 1] == ">" { return j + 2 }
                j += 2
                continue
            }
            guard chars[j + 1] == mark else { j += 2; continue }
            guard j + 2 < count, chars[j + 2] != "\0" else { return nil }
            if chars[j + 2] == ">" { return j + 3 }
            j += 3
        }
        return nil
    }

    /// Where a match of `form` that starts at `i` ends, in scalars.
    private func match(_ form: NSRegularExpression, at i: Int) -> Int? {
        let from = utf16[i]
        guard let found = form.firstMatch(in: text, options: .anchored,
                                          range: NSRange(location: from, length: utf16[count] - from)) else { return nil }
        var end = i
        while utf16[end] < from + found.range.length { end += 1 }
        return end
    }

    private static func form(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    private static let space = #"[ \t\n\x{0B}\f\r]"#
    static let uriAutolink = form(#"<[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\x00-\x20<>]*>"#)
    static let declaration = form(#"<![A-Z]+"# + space + #"+[^>\x00]*>"#)

    // MARK: Links

    /// The end of the address and title after a link's "](", as the parser reads them, with its ")".
    private func linkTailEnd(at p: Int) -> Int? {
        guard p < count, chars[p] == "(" else { return nil }
        let start = skippingSpaces(from: p + 1)
        guard let address = addressEnd(at: start) else { return nil }
        let title = skippingSpaces(from: address)
        let close = skippingSpaces(from: title == address ? title : titleEnd(at: title) ?? title)
        return close < count && chars[close] == ")" ? close + 1 : nil
    }

    /// The end of the "(...)" right after the "]" of "^[": up to the ")" that closes its "(", with escapes.
    private func attributesEnd(at p: Int) -> Int? {
        guard p < count, chars[p] == "(", let close = closes[p] else { return nil }
        return close + 1
    }

    private func skippingSpaces(from i: Int) -> Int {
        var j = i
        while j < count, Self.spaceOfSyntax(chars[j]) { j += 1 }
        return j
    }

    private func addressEnd(at k: Int) -> Int? {
        if k < count, chars[k] == "<" {
            var j = k + 1
            while j < count {
                switch chars[j] {
                case ">": return j + 1 < count ? j + 1 : nil
                case "\\": j += 2
                case "\n", "<": return nil
                default: j += 1
                }
            }
            return nil
        }
        var j = k, depth = 0
        while j < count {
            let c = chars[j]
            if c == "\\", j + 1 < count, Self.punctuation(chars[j + 1]) {
                j += 2
            } else if c == "(" {
                depth += 1; j += 1
                if depth > 32 { return nil }
            } else if c == ")" {
                if depth == 0 { break }
                depth -= 1; j += 1
            } else if Self.space(c) {
                if j == k { return nil }
                break
            } else {
                j += 1
            }
        }
        return j < count ? j : nil              // a "(" that a space leaves open is no fault for the parser
    }

    /// The end of the longest title that starts at `k`: in quotes, or in parentheses with none open inside.
    private func titleEnd(at k: Int) -> Int? {
        guard k < count, ["\"", "'", "("].contains(chars[k]) else { return nil }
        let close: Unicode.Scalar = chars[k] == "(" ? ")" : chars[k]
        var j = k + 1, longest: Int?
        while j < count, chars[j] != "\0" {
            let escaped = j - 1 > k && chars[j - 1] == "\\"
            if chars[j] == close {
                if !escaped { return j + 1 }
                longest = j + 1
            } else if close == ")", chars[j] == "(", !escaped {
                break
            }
            j += 1
        }
        return longest
    }

    /// The bare "http", "https" or "ftp" address that the parser links at the ":" at `k`: where it ends, from that
    /// ":", and where the punctuation that the parser cut from that end stops.
    private func urlLink(at k: Int) -> (end: Int, stop: Int)? {
        guard k + 3 < count, chars[k + 1] == "/", chars[k + 2] == "/", Self.hostCharacter(chars[k + 3]) else { return nil }
        var s = k
        while s > 0, Self.letter(chars[s - 1]) { s -= 1 }
        guard ["http", "https", "ftp"].contains(String(String.UnicodeScalarView(chars[s..<k])).lowercased()),
              domainHolds(from: k + 3, short: true) else { return nil }
        let stop = addressStop(from: k + 3)
        return (trimmed(from: k, to: stop), stop)
    }

    /// The bare "www." address that the parser links at `k`.
    private func wwwLink(at k: Int) -> (end: Int, stop: Int)? {
        guard k + 3 < count, chars[k + 1] == "w", chars[k + 2] == "w", chars[k + 3] == "." else { return nil }
        if k > 0 {
            let before = chars[k - 1]
            guard Self.space(before) || "*_~(".unicodeScalars.contains(before) else { return nil }
        }
        guard domainHolds(from: k, short: false) else { return nil }
        let stop = addressStop(from: k)
        let end = trimmed(from: k, to: stop)
        return end > k ? (end, stop) : nil
    }

    private func addressStop(from i: Int) -> Int {
        var j = i
        while j < count, !Self.space(chars[j]), chars[j] != "<" { j += 1 }
        return j
    }

    /// Whether the domain that starts at `d` is one that the parser links: no "_" in its last two parts, and a dot
    /// unless `short`. Like the parser, it reads ASCII only (a longer character ends it) and stops a byte before the
    /// text's end, and it steps over a backslash.
    private func domainHolds(from d: Int, short: Bool) -> Bool {
        guard chars[d].isASCII else { return short }        // its second byte ends it at once
        let size = utf8[count] - utf8[d]
        var j = d + 1, dots = 0, last = 0, before = 0
        while j < count, utf8[j] - utf8[d] < size - 1 {
            if chars[j] == "\\", utf8[j] - utf8[d] < size - 2 { j += 1 }
            let c = chars[j]
            if c == "_" {
                last += 1
            } else if c == "." {
                before = last; last = 0; dots += 1
            } else if c != "-", !c.isASCII || Self.hostSpace(c) || Self.punctuation(c) {
                break
            }
            j += 1
        }
        return (dots > 10 || before == 0 && last == 0) && (short || dots > 0)   // past 10 dots it takes an "_" too
    }

    /// Where an address that runs from `base` to `stop` ends once the parser has cut its last punctuation: "?", "!",
    /// ".", ",", ":", "*", "_", "~", quotes, a ";" (with the "&name" of an entity before it), and a ")" that no "("
    /// opened.
    private func trimmed(from base: Int, to stop: Int) -> Int {
        var end = stop, opened = 0, closed = 0
        for c in chars[base..<stop] {
            if c == "(" { opened += 1 } else if c == ")" { closed += 1 }
        }
        while end > base {
            let c = chars[end - 1]
            if "?!.,:*_~'\"".unicodeScalars.contains(c) {
                end -= 1
            } else if c == ";" {
                var k = end - 2
                while k > base, Self.letter(chars[k]) { k -= 1 }
                if k < end - 2, chars[k] == "&" { end = k } else { end -= 1 }
            } else if c == ")", closed > opened {
                closed -= 1; end -= 1
            } else {
                break
            }
        }
        return end
    }

    // MARK: Characters as the parser sorts them

    /// A space that ends a bare address or a link's address, and that may come before "www.".
    private static func space(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" }
    /// A space between the parts of a tag or of a link's "(...)".
    private static func spaceOfSyntax(_ c: Unicode.Scalar) -> Bool { space(c) || c == "\u{0B}" || c == "\u{0C}" }
    /// An ASCII space that ends a domain.
    private static func hostSpace(_ c: Unicode.Scalar) -> Bool { space(c) || c == "\u{0C}" }
    private static func punctuation(_ c: Unicode.Scalar) -> Bool {
        c.isASCII && (0x21...0x2F ~= c.value || 0x3A...0x40 ~= c.value || 0x5B...0x60 ~= c.value
                      || 0x7B...0x7E ~= c.value)
    }
    private static func letter(_ c: Unicode.Scalar) -> Bool { 0x41...0x5A ~= c.value || 0x61...0x7A ~= c.value }
    private static func alphanumeric(_ c: Unicode.Scalar) -> Bool { letter(c) || 0x30...0x39 ~= c.value }
    private static func emailName(_ c: Unicode.Scalar) -> Bool {
        alphanumeric(c) || ".!#$%&'*+/=?^_`{|}~-".unicodeScalars.contains(c)
    }
    /// What may come after the "//" of a bare address: no space and no punctuation (a symbol, such as "€", may).
    private static func hostCharacter(_ c: Unicode.Scalar) -> Bool {
        if c.isASCII { return !hostSpace(c) && !punctuation(c) }
        switch c.properties.generalCategory {
        case .spaceSeparator, .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: return false
        default: return true
        }
    }
}
