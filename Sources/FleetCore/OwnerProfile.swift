import Foundation

/// **The owner's name and language, for the agents** (owner feature `owner_profile`, owner API 1.200). The owner,
/// 16 November 2026: "when the fleet is setup on an app with spanish language, bots should talk in Spanish", and
/// "something like your profile with the user name so the fleet can address them properly?", with "Mac account +
/// Settings row" to its picture. The hub asks every agent session to call the owner by the fleet's setting
/// `owner.name` and to write what the owner's apps show in `owner.language`.
///
/// **The Mac fills what the fleet has not set, under the hood** (`FleetStore.ownerProfileTick`): the first of the Mac's
/// preferred languages, and the first name of its account. It is the Mac's language and not the app's own: an agent
/// writes any language, and the app shows only the ones that it has, so a Mac in French gets agents in French and an
/// app in English. A value that is set — by an earlier Mac, the owner's own agent, or his Name row in Settings ›
/// General › Your profile, an empty one included — is never taken back.
public enum OwnerProfile {
    public static let feature = "owner_profile"
    public static let language = "owner.language"
    public static let name = "owner.name"
    /// The longest name that the hub keeps, in Unicode scalars as it counts them (`hub.name_check`).
    public static let nameMax = 40

    /// The BCP 47 tag of the first preferred language ("es-ES"), as the hub's check takes it: hyphens, a language of two
    /// or three letters, at most three more parts and 35 characters (`hub.language_check`). nil for none, and for
    /// English, which the agents write with no setting: a Mac in English sends nothing, and leaves the setting to a Mac
    /// of the owner's in another language.
    public static func languageTag(_ preferred: [String] = Locale.preferredLanguages) -> String? {
        guard let first = preferred.first else { return nil }
        let tag = first.replacingOccurrences(of: "_", with: "-")
        guard tag.count <= 35, tag.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,3}$"#, options: .regularExpression) != nil,
              tag.split(separator: "-").first?.lowercased() != "en" else { return nil }
        return tag
    }

    /// A name as the hub keeps it: one space between its words, at most `nameMax` letters of any script, spaces and
    /// . ' ’ -, a letter's marks included ("रवि" has one); "" for none. nil for one that the hub would refuse
    /// (`hub.name_check`, which counts Unicode scalars after NFC, as this does).
    public static func keptName(_ typed: String) -> String? {
        // a variation selector chooses a letter's form, and the name keeps its letters without it (`hub.OWNER_NAME_FORMS`)
        let forms = String(String.UnicodeScalarView(typed.unicodeScalars.filter { !isForm($0) }))
        let name = forms.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Each scalar on its own, as the hub checks each character: a regex of String matches whole characters, and
        // there an invisible mark (U+034F) rode with the letter before it.
        guard name.unicodeScalars.count <= nameMax, name.unicodeScalars.allSatisfy(inName) else { return nil }
        return name
    }

    /// The variation selectors (`hub.OWNER_NAME_FORMS`).
    static func isForm(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x180B...0x180D, 0x180F, 0xFE00...0xFE0F, 0xE0100...0xE01EF: true
        default: false
        }
    }

    /// A scalar that a name may hold (`hub.name_check`): a letter or a mark that Unicode does not make invisible
    /// (`hub.OWNER_NAME_HIDDEN`), a space, or . ' ’ -.
    static func inName(_ scalar: Unicode.Scalar) -> Bool {
        if " .'\u{2019}-".unicodeScalars.contains(scalar) { return true }
        guard !scalar.properties.isDefaultIgnorableCodePoint else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// The words of an account that is no person's own: anywhere in its full name ("IT Admin"), and as its first word
    /// ("Guest User", "Test Account"), where a surname such as Root or Guest cannot be.
    static let accountWords: Set<String> = ["admin", "administrator"]
    static let accountFirstWords: Set<String> = ["guest", "user", "root", "test", "owner"]

    /// The first name of the Mac's account ("Alex" of "Alex Morgan"), as the hub keeps a name. nil for an account with no
    /// full name of its own (a full name that is its short name, such as "admin"), for one with a word of an account
    /// that is no person's (`accountWords`), and when that first name is one that the hub would refuse. Only the first
    /// name is checked: "Alex 🚀" and a full name of more than 40 letters still give theirs.
    public static func accountName(full: String = NSFullUserName(), short: String = NSUserName()) -> String? {
        let words = full.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let firstWord = words.first, words.joined(separator: " ") != short,
              !accountFirstWords.contains(firstWord.lowercased()),
              !words.contains(where: { accountWords.contains($0.lowercased()) }) else { return nil }
        let given = PersonNameComponentsFormatter().personNameComponents(from: words.joined(separator: " "))?.givenName
        for first in [given, firstWord] {
            if let first, let name = keptName(first), !name.isEmpty { return name }
        }
        return nil
    }

    /// The Mac's values for the settings that the fleet has not set: those that the Mac gives it.
    public static func unset(_ page: OwnerProfilePage, language: String?, name: String?) -> [String: String] {
        var values: [String: String] = [:]
        if let language, page.language?.set == false { values[Self.language] = language }
        if let name, page.name?.set == false { values[Self.name] = name }
        return values
    }

    /// The body of a write: one value or more, under the request id and the hub's generation. `onlyUnset`: the hub sets
    /// only what the fleet has not set, in its own write (owner API 1.200), so a fill never takes back a value that
    /// the owner saved between its read and its write.
    static func body(_ values: [String: String], requestID: String, database: String, onlyUnset: Bool = false) throws
        -> Data {
        var body: [String: Any] = ["request_id": requestID, "db": database, "settings": values]
        if onlyUnset { body["only_unset"] = true }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}

/// The two settings as `GET /ui/settings` gives them. nil for a setting that the hub does not know.
public struct OwnerProfilePage: Decodable, Equatable, Sendable {
    public struct Entry: Decodable, Equatable, Sendable {
        public let value: String
        /// The fleet has a value of its own, which the Mac does not take back.
        public let set: Bool
        public init(value: String, set: Bool) { self.value = value; self.set = set }
    }

    public let db: String
    public let name: Entry?
    public let language: Entry?

    enum CodingKeys: String, CodingKey { case db, settings }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        db = try values.decode(String.self, forKey: .db)
        let settings = (try? values.decodeIfPresent([String: SettingValue].self, forKey: .settings)) ?? nil
        name = settings?[OwnerProfile.name]?.entry
        language = settings?[OwnerProfile.language]?.entry
    }

    public init(db: String, name: Entry?, language: Entry?) { self.db = db; self.name = name; self.language = language }

    /// One setting of the page, whatever its value's type: only a string value is one of these two.
    private struct SettingValue: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let value = try? values.decode(String.self, forKey: .value)
            let set = (try? values.decode(Bool.self, forKey: .set)) ?? false
            entry = value.map { Entry(value: $0, set: set) }
        }
        enum CodingKeys: String, CodingKey { case value, set }
    }
}

/// `GET /ui/settings` for the two settings, and `POST /ui/settings` for a change of them.
public final class OwnerProfileClient: Sendable {
    private static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60        // the hub commits and pushes team.json before it answers
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration)
    }()
    private var session: URLSession { Self.shared }

    public init() {}

    public func read(hub: URL, database: String) async throws -> OwnerProfilePage {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/settings"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let page = try JSONDecoder().decode(OwnerProfilePage.self, from: await fetch(request))
        guard page.db == database else { throw HubError.invalidResponse }
        return page
    }

    /// One value or more. The same `requestID` again is the same request: the hub answers a repeat with its receipt.
    public func save(_ values: [String: String], hub: URL, database: String, client: String, onlyUnset: Bool = false,
                     requestID: String = UUID().uuidString.lowercased()) async throws -> SettingsReceipt {
        var request = URLRequest(url: hub.appendingPathComponent("ui/settings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try OwnerProfile.body(values, requestID: requestID, database: database, onlyUnset: onlyUnset)
        let receipt = try JSONDecoder().decode(SettingsReceipt.self, from: await fetch(request))
        guard receipt.ok, receipt.request_id == requestID, receipt.client == client else { throw HubError.invalidResponse }
        return receipt
    }

    /// Gives the fleet the Mac's language and name where it has not set them, one write for each, so that a value
    /// that the hub refuses keeps nothing else out: true when the hub changed one.
    public func fill(hub: URL, database: String, client: String, language: String?, name: String?) async throws -> Bool {
        let values = OwnerProfile.unset(try await read(hub: hub, database: database), language: language, name: name)
        var changed = false
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            let receipt = try? await save([key: value], hub: hub, database: database, client: client, onlyUnset: true)
            changed = changed || receipt?.changed.isEmpty == false
        }
        return changed
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.hubData(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(.read(status: response.statusCode, body: data)) }
        return data
    }
}
