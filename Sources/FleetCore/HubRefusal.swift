import Foundation

/// A value that stands inside the words of a refusal (`names` of an answer, UI-API.md 1.181): a text or a whole number.
/// A server, an address or an agent is a text; a count is a number.
public enum RefusalName: Sendable, Equatable, Codable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    case text(String)
    case number(Int)

    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int) { self = .number(value) }

    /// The value as the words write it: the text as it is, or the digits of the number.
    public var written: String {
        switch self {
        case .text(let text): text
        case .number(let number): String(number)
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Int.self) { self = .number(number); return }
        self = .text(try value.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .text(let text): try value.encode(text)
        case .number(let number): try value.encode(number)
        }
    }
}

/// **What the hub refused, with its status, as one value** (the design `hub-refusal-words-design.md`, "The app"; the
/// owner's "Yes, as shown" of 16 November 2026). The hub answers `{"error": <English>, "code": <one of its table>,
/// "names": {...}}` (UI-API.md 1.181): `error` is always there and is the hub's own English; `code` stands on the
/// refusals that have one, and `names` only where the words hold a name.
///
/// - `hubWords` is `error` as it came, and it is what the app shows for a refusal that has no code, for a code that
///   it does not know, and on a device whose language is English.
/// - `words` is what the owner reads: the app's own words for a code that it knows, in the language of the device,
///   and `hubWords` for every other.
/// - **Code that decides something reads `code`, never `words`** (`means(_:)`): the words are for a person, and in
///   Spanish they are not the hub's.
///
/// One decoder, `read(status:body:)`, makes it for every funnel that talks to the hub.
public struct HubRefusal: Sendable, Equatable, Codable {
    public let status: Int
    /// The hub's `error`, as it came: its English, bounded to 500 characters and never empty (`HubError.unexplained`
    /// when the answer carried none).
    public let hubWords: String
    /// The hub's code of this sentence (a-z, 0-9 and `_`, 2 to 40 characters), or nil: an older hub sends none, and a
    /// refusal that no person meets has none.
    public let code: String?
    /// The values inside the words, by name, as the hub wrote them.
    public let names: [String: RefusalName]

    public init(status: Int, hubWords: String, code: String? = nil, names: [String: RefusalName] = [:]) {
        self.status = status
        self.hubWords = hubWords
        self.code = code
        self.names = names
    }

    /// A refusal that an older version of the app kept on disk had no `code` and no `names`; only these two may be
    /// missing from a record.
    public init(from decoder: Decoder) throws {
        let record = try decoder.container(keyedBy: CodingKeys.self)
        status = try record.decode(Int.self, forKey: .status)
        hubWords = try record.decode(String.self, forKey: .hubWords)
        code = try record.decodeIfPresent(String.self, forKey: .code)
        names = try record.decodeIfPresent([String: RefusalName].self, forKey: .names) ?? [:]
    }

    /// What the owner reads: the app's own words for the code, in the language of the device (`RefusalWords`), else the
    /// hub's. The hub's English stands for a refusal with no code, for a code that the app does not know, for a name
    /// that the words need and the refusal lacks, for a language that has no words for the code, and on a device
    /// whose language is English.
    ///
    /// The fallback of a refusal that carried no words (`HubError.unexplained`) is the app's own sentence, not the
    /// hub's, so it has its words in the device's language as every word of the app has.
    public var words: String {
        if let own = RefusalWords.words(for: self) { return own }
        return hubWords == HubError.unexplained ? String(l10n: "Unexpected HTTP response.") : hubWords
    }

    /// The hub's own sentence, or nil when it gave none (the answer carried no words): a screen then says it in its
    /// own words (`HubError.said`).
    public var said: String? {
        let hub = hubWords.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hub.isEmpty, hub != HubError.unexplained else { return nil }
        return words.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: the decoder

    /// The refusal that an answer of `status` with this `body` is. **The one decoder of the hub's refusals**: every
    /// funnel of the app calls it, so that a field that the hub adds next is read in one place.
    ///
    /// Nothing in a body makes it fail: a body that is no JSON, or whose `error` is no text, is a refusal with the
    /// fallback words and its status, as it always was. A `code` that is not one (`isCode`) is ignored, and a name
    /// that is neither a text nor a whole number is left out, so one bad field never costs the owner the others.
    public static func read(status: Int, body: Data) -> HubRefusal {
        let sent = try? JSONDecoder().decode(Sent.self, from: body)
        let said = (sent?.error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return HubRefusal(status: status, hubWords: said.isEmpty ? HubError.unexplained : String(said.prefix(500)),
                          code: sent?.code.flatMap { isCode($0) ? $0 : nil }, names: sent?.names ?? [:])
    }

    /// A code or a name's key: small letters, digits and `_`, 2 to 40 characters for a code (UI-API.md 1.181), and
    /// 1 to 40 for a key.
    static func isCode(_ text: String, least: Int = 2) -> Bool {
        (least...40).contains(text.count) && text.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5f }
    }

    /// The most that the hub writes into one name, and how many names an answer may carry here.
    static let nameMost = 200, namesMost = 16

    /// The three fields that the app reads of a refusal's body, each of them apart: a field of another kind is nil,
    /// never an error.
    private struct Sent: Decodable {
        let error: String?
        let code: String?
        let names: [String: RefusalName]

        private enum Keys: String, CodingKey { case error, code, names }

        /// A name of one value that does not decode, so that its neighbours still do.
        private struct Lossy: Decodable {
            let name: RefusalName?
            init(from decoder: Decoder) { name = try? RefusalName(from: decoder) }
        }

        init(from decoder: Decoder) throws {
            let body = try decoder.container(keyedBy: Keys.self)
            error = try? body.decode(String.self, forKey: .error)
            code = try? body.decode(String.self, forKey: .code)
            var kept: [String: RefusalName] = [:]
            for (key, value) in (try? body.decode([String: Lossy].self, forKey: .names)) ?? [:] {
                guard kept.count < HubRefusal.namesMost, HubRefusal.isCode(key, least: 1), let name = value.name else { continue }
                if case .text(let text) = name { kept[key] = .text(String(text.prefix(HubRefusal.nameMost))) } else { kept[key] = name }
            }
            names = kept
        }
    }
}
