import CryptoKit
import Foundation
import Network

/// One owner device of `GET /ui/owner/devices` (UI-API.md, "The owner's phone"; MOBILE-APP.md 6.5 and 7): a device of
/// the owner's own beside his Mac — today his phone — which reaches the hub over the private network with its own
/// address **and** its own key. The Mac keeps the rule of today: its address, and no key.
///
/// No field of this route is a secret: `key` is a flag, never the key or its SHA-256, and `code_expires` is a time,
/// never a code. The hub keeps neither a key nor a code, only their SHA-256.
public struct OwnerDevice: Decodable, Identifiable, Equatable, Sendable {
    public let device: String
    public let label: String
    public let address: String
    /// The device took a key and the hub holds its SHA-256.
    public let key: Bool
    /// When it took that key.
    public let since: Double?
    /// Its last read that passed the key check.
    public let last_seen: Double?
    /// Its last request of any kind, a refused one included, and the hub's answer to it (nil when that request
    /// passed). Together they tell a phone that never reached the hub from one that the hub refused: `last_seen`
    /// alone cannot, because the hub writes it only after the key check passes.
    public let last_contact: Double?
    public let last_answer: String?
    /// When the open enrollment code stops working, or nil without one.
    public let code_expires: Double?
    /// The caller is this device. The Mac app never sees it true, because `validate_team` refuses a device on the
    /// owner's own address; the phone reads the same route and does.
    public let this_device: Bool
    /// Whether this hub reports contacts at all. A hub from before them leaves the two fields out, and saying
    /// "it has not reached the hub yet" about an unreported fact would not be true.
    public let reportsContact: Bool
    /// Owner feature `door_calls` (API 1.81): the phone's own signing key and the HMAC that binds it to the one-time
    /// value of this Mac's QR, and whether the owner key certified it. nil and false for a device that sent none.
    public let signing_key: String?
    public let binding: String?
    public let certified: Bool
    /// Owner feature `recovery_copy` (API 1.95): the phone's second key, which this Mac seals the recovery code to once
    /// its binding to the QR's one-time value matched, and where that copy stands. nil for an older phone.
    public let recovery_key: String?
    public let recovery_binding: String?
    public let recovery: RecoveryCopyState?
    public var id: String { device }

    /// Where a phone's copy of the recovery code stands on the hub: a box waits for it, or it said that it holds it.
    public struct RecoveryCopyState: Decodable, Equatable, Sendable {
        public let sealed: Bool
        public let held: Double?
    }

    /// The phone sent a recovery key, and neither a box nor its copy is on the hub: this Mac seals one.
    public var wantsRecoveryCopy: Bool { recovery_key != nil && recovery_binding != nil && recovery == nil }

    enum CodingKeys: String, CodingKey {
        case device, label, address, key, since, last_seen, last_contact, last_answer, code_expires, this_device
        case signing_key, binding, certified, recovery_key, recovery_binding, recovery
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        device = try values.decode(String.self, forKey: .device)
        label = try values.decode(String.self, forKey: .label)
        address = try values.decode(String.self, forKey: .address)
        key = try values.decode(Bool.self, forKey: .key)
        since = try values.decodeIfPresent(Double.self, forKey: .since)
        last_seen = try values.decodeIfPresent(Double.self, forKey: .last_seen)
        last_contact = try values.decodeIfPresent(Double.self, forKey: .last_contact)
        last_answer = try values.decodeIfPresent(String.self, forKey: .last_answer)
        code_expires = try values.decodeIfPresent(Double.self, forKey: .code_expires)
        this_device = try values.decodeIfPresent(Bool.self, forKey: .this_device) ?? false
        reportsContact = values.contains(.last_contact)
        signing_key = try values.decodeIfPresent(String.self, forKey: .signing_key)
        binding = try values.decodeIfPresent(String.self, forKey: .binding)
        certified = try values.decodeIfPresent(Bool.self, forKey: .certified) ?? false
        recovery_key = try values.decodeIfPresent(String.self, forKey: .recovery_key)
        recovery_binding = try values.decodeIfPresent(String.self, forKey: .recovery_binding)
        recovery = try values.decodeIfPresent(RecoveryCopyState.self, forKey: .recovery)
    }

    public var isValid: Bool {
        OwnerDevices.isName(device) && OwnerDevices.label(label) != nil && OwnerDevices.isAddress(address) &&
            [since, last_seen, last_contact, code_expires].allSatisfy { $0.map { $0.isFinite && $0 > 0 } ?? true } &&
            (last_answer?.count ?? 0) <= 64
    }

    /// An open enrollment code, or nil when none works now.
    public func openCode(now: Double) -> Double? { code_expires.flatMap { $0 > now ? $0 : nil } }

    /// What this device is now, in one line, and whether the owner has something to do about it. The one line says
    /// the most important fact: a refusal of the hub first, because that is what the owner must act on, then the key,
    /// an open code and the last read. A phone that never reached the hub reads differently from one that the hub
    /// refused — `last_seen` cannot say that, because the hub writes it only after the key check passes — and a
    /// refusal that this app does not know gets a neutral sentence, never a raw code.
    public func words(now: Double) -> (words: String, attention: Bool) {
        let when = last_contact.map { Servers.age($0, now: now) } ?? ""
        switch last_answer {
        case "device_not_enrolled": return ("It reached the hub \(when), without a key.", true)
        case "device_key_required": return ("It reached the hub \(when) and sent no key.", true)
        case "device_key_mismatch": return ("It sent a key that is not this device's, \(when).", true)
        case "device_not_allowed": return ("It asked \(when) for a page that stays on this Mac.", false)
        case "key_not_expected": return ("It sent a key where the hub expects none, \(when).", false)
        case .some: return ("The hub refused its last request, \(when).", true)
        case .none: break
        }
        if !key {
            if let open = openCode(now: now) { return ("A code is open · \(OwnerDevices.left(open, now: now))", false) }
            // Only a hub that reports contacts can say that the device never arrived.
            return (reportsContact && last_contact == nil ? "No key yet · it has not reached the hub" : "No key yet", true)
        }
        guard let last_seen else { return ("Has its key · no read yet", false) }
        return ("Last read \(Servers.age(last_seen, now: now))", false)
    }

    /// **The same fact as one mark.** The owner, 20 October 2026: "not even sentences, just a check or a cross, and
    /// on hover probably show the detail?" So the row answers with a mark and the sentence above lives behind it.
    ///
    /// Whether this phone can reach the hub is a yes-or-no fact, which is what makes it a mark. The two refusals
    /// that are the hub doing its job — a page that stays on this Mac, a key where none is expected — are not
    /// failures of the device, so they warn instead of crossing it; a code that is open is work in progress.
    public func mark(now: Double) -> (state: MarkState, words: String, detail: String) {
        let said = words(now: now).words
        switch last_answer {
        case "device_not_enrolled": return (.bad, "No key", said)
        case "device_key_required": return (.bad, "No key sent", said)
        case "device_key_mismatch": return (.bad, "Wrong key", said)
        case "device_not_allowed": return (.warn, "One page refused", said)
        case "key_not_expected": return (.warn, "Key not expected", said)
        case .some: return (.bad, "Refused", said)
        case .none: break
        }
        if !key {
            return openCode(now: now) != nil ? (.working, "Code open", said) : (.bad, "No key yet", said)
        }
        return (.good, last_seen == nil ? "Has its key" : "Reaching the hub", said)
    }
}

/// `GET /ui/owner/devices`: the owner's devices and how many the hub takes.
public struct OwnerDeviceList: Decodable, Sendable {
    public let db: String
    public let limit: Int
    public let devices: [OwnerDevice]

    public func validate(database: String) throws {
        guard db == database, limit > 0, limit <= 64, devices.count <= limit,
              Set(devices.map(\.device)).count == devices.count,
              Set(devices.map(\.address)).count == devices.count,
              devices.allSatisfy(\.isValid) else { throw HubError.invalidResponse }
    }

    public func device(_ name: String) -> OwnerDevice? { devices.first { $0.device == name } }
}

/// The rules of the owner's devices that the app checks before it sends, and the words that go with them. The hub
/// checks everything again (`validate_team`), and its refusal is what the form shows.
public enum OwnerDevices {
    /// The hub feature that carries this section, in `ui_features`.
    public static let feature = "mobile"
    /// The hub feature of Add device with no fields: the Mac shows a code and its QR at once, and the hub adds the phone
    /// that brings it with the address it calls from (the owner, 3 November 2026).
    public static let codeAlone = "device_by_code"
    /// A device name, as `team.json` takes it: 2 to 31 characters, a-z, 0-9 and -, starting with a letter.
    public static let namePattern = "^[a-z][a-z0-9-]{1,30}$"
    /// An enrollment code works for ten minutes, and once.
    public static let codeLife: Double = 600

    public static func isName(_ text: String) -> Bool {
        text.range(of: namePattern, options: .regularExpression) != nil
    }

    /// A label as the hub takes it: 1 to 40 characters on one line, without spaces at the ends; else nil.
    public static func label(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(value.count), !value.contains(where: \.isNewline) else { return nil }
        return value
    }

    /// The hub takes an IP address only, because the address is the device's identity.
    public static func isAddress(_ text: String) -> Bool {
        IPv4Address(text) != nil || IPv6Address(text) != nil
    }

    /// How long an enrollment code still works, in a few words.
    public static func left(_ until: Double, now: Double) -> String {
        let seconds = until - now
        if seconds <= 0 { return "expired" }
        if seconds < 90 { return "\(Int(seconds.rounded(.up))) seconds left" }
        return "\(Int((seconds / 60).rounded(.up))) minutes left"
    }

    /// What the picture of a code carries: the hub and the code, so that a scanner on the device needs nothing else.
    /// Fleet Mobile takes a typed code today (MOBILE-APP.md 6.5, step 2), and this is the same two facts for the
    /// scanner that comes with a later phase.
    /// `bind` (owner feature `door_calls`): a one-time value that only the picture carries, which the phone never
    /// sends to the hub. The phone binds its own signing key to it (`DeviceBinding`), so this Mac can certify that key
    /// and the hub cannot slip in a key of its own.
    public static func enrollPayload(hub: URL, code: String, bind: String? = nil) -> String {
        var parts = URLComponents()
        parts.scheme = "fleet"
        parts.host = "enroll"
        parts.queryItems = [.init(name: "hub", value: hub.absoluteString), .init(name: "code", value: code)] +
            (bind.map { [.init(name: "bind", value: $0)] } ?? [])
        return parts.url?.absoluteString ?? code
    }

    /// A code as the hub gives it: eight characters of its own alphabet, as `XXXX-XXXX`. Anything else is not a code
    /// of this hub, and the page says so instead of drawing a picture of it.
    public static func isCode(_ text: String) -> Bool {
        text.range(of: "^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}-[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}$",
                   options: .regularExpression) != nil
    }

    /// The name that `team.json` holds, from the label that the owner typed: a-z, 0-9 and -, starting with a letter,
    /// at most 31 characters, and not one that another device has. The owner never types it: it is the key of an
    /// entry, not a name he uses.
    public static func name(from label: String, taken: [String]) -> String {
        let letters = label.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        var stem = String(String(letters).split(separator: "-").joined(separator: "-").prefix(31))
        while let first = stem.first, !first.isLetter { stem.removeFirst() }
        if stem.isEmpty { stem = "device" }
        guard taken.contains(stem) else { return stem }
        for number in 2...99 where !taken.contains("\(String(stem.prefix(28)))-\(number)") {
            return "\(String(stem.prefix(28)))-\(number)"
        }
        return stem
    }
}

/// One device as the owner saves it (`POST /ui/owner/devices`): its name, its label and its own address.
public struct OwnerDeviceInput: Codable, Equatable, Sendable {
    public var device: String
    public var label: String
    public var address: String

    public init(device: String = "", label: String = "", address: String = "") {
        self.device = device; self.label = label; self.address = address
    }

    public var normalized: Self {
        OwnerDeviceInput(device: device.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                         label: OwnerDevices.label(label) ?? label.trimmingCharacters(in: .whitespacesAndNewlines),
                         address: address.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The same device with the `team.json` name that its label gives it, when it has none of its own.
    public func named(taken: [String]) -> Self {
        var value = normalized
        guard value.device.isEmpty, OwnerDevices.label(value.label) != nil else { return value }
        value.device = OwnerDevices.name(from: value.label, taken: taken)
        return value
    }

    /// Why the hub would refuse this device, or nil. `existing` is the list that the page read.
    public func problem(existing: [OwnerDevice], limit: Int) -> String? {
        let value = normalized
        guard OwnerDevices.isName(value.device) else {
            return "Use a name of 2 to 31 characters: a-z, 0-9 and -, starting with a letter."
        }
        guard !existing.contains(where: { $0.device == value.device }) else {
            return "A device with this name is in Founderizer. Open it instead, or use another name."
        }
        guard OwnerDevices.label(value.label) != nil else { return "Give a label of 1 to 40 characters on one line." }
        guard OwnerDevices.isAddress(value.address) else {
            return "Give the device's own address on your private network, for example 100.84.1.20."
        }
        guard !existing.contains(where: { $0.address == value.address }) else {
            return "Another device has this address. Each device needs its own."
        }
        guard existing.count < limit else { return "Founderizer takes \(limit) devices. Remove one before you add another." }
        return nil
    }

    public func payload() throws -> String { String(decoding: try JSONEncoder().encode(normalized), as: UTF8.self) }
}

/// **A phone's signing key, bound to the Mac's QR** (owner feature `door_calls`, API 1.81). The QR carries `bind`, 32
/// random bytes in base64url, which only the picture holds. At enrollment the phone sends its own P-256 key with
/// HMAC-SHA256(key: bind, data: the key's 65 bytes), and this Mac, which kept `bind`, checks that HMAC before it signs
/// the key's certificate with the owner key. The hub never sees `bind`, so it can forge no binding of a key of its own.
public enum DeviceBinding {
    /// A new one-time value for one QR.
    public static func newBind() -> String {
        base64url(Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }))
    }

    /// The binding of a public key (standard base64 of `04 || X || Y`) to `bind`, as standard base64, or nil for a
    /// value that is not one.
    public static func binding(bind: String, key: String) -> String? {
        guard let secret = unbase64url(bind), secret.count == 32, let point = Data(base64Encoded: key),
              point.count == 65, point.first == 0x04 else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: point, using: SymmetricKey(data: secret))
        return Data(mac).base64EncodedString()
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func unbase64url(_ text: String) -> Data? {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while standard.count % 4 != 0 { standard += "=" }
        return Data(base64Encoded: standard)
    }
}

/// **The one-time values of the QRs that this Mac drew**, kept for an hour after their code stops working, so that a
/// phone that enrolled while the page was closed is certified the next time the page reads the hub. One is dropped once
/// it certified a key. They live in this Mac's preferences: whoever reads those holds the owner key already.
public enum DeviceBinds {
    static let key = "deviceBinds"

    public static func remember(_ bind: String, until: Double, in defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        all[bind] = until
        defaults.set(all, forKey: key)
    }

    public static func all(now: Double = Date().timeIntervalSince1970, in defaults: UserDefaults = .standard) -> [String] {
        let all = (defaults.dictionary(forKey: key) as? [String: Double] ?? [:]).filter { $0.value > now }
        defaults.set(all, forKey: key)
        return all.keys.sorted()
    }

    public static func forget(_ bind: String, in defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        all[bind] = nil
        defaults.set(all, forKey: key)
    }
}

