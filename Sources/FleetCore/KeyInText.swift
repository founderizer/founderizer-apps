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
        // A run comes first only when it ends before the key with a shape begins: a run that holds that key is no
        // better a guess at it, and `NAME=sk-…` is the key and not its name.
        for match in run.matches(in: text, range: whole) where found.map({ NSMaxRange(match.range) <= $0.location }) ?? true {
            let value = assigned(match.range, of: words)
            if value.length >= 32, !inAddressPath(value, of: words), looksRandom(words.substring(with: value)) { found = value; break }
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

    /// Whether a run stands in the path of a web address, where the id of a document, a file or a commit reads as
    /// random and is no key: after `://` and before the address's query. A run in a query (`?key=…`) is looked at, and
    /// a key with a shape of its own is found anywhere.
    static func inAddressPath(_ range: NSRange, of text: NSString) -> Bool {
        // The word that holds the run: from the space before it.
        var start = range.location
        while start > 0, let scalar = Unicode.Scalar(text.character(at: start - 1)),
              !CharacterSet.whitespacesAndNewlines.contains(scalar) { start -= 1 }
        let before = text.substring(with: NSRange(location: start, length: range.location - start))
        guard let scheme = before.range(of: "://") else { return false }
        let address = before[scheme.upperBound...]
        return !address.contains("?") && !address.contains("#")
    }

    /// Whether `text` holds something that looks like a key.
    public static func contains(_ text: String) -> Bool { first(in: text) != nil }

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
