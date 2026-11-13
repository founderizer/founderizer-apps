import CryptoKit
import Foundation

/// **The owner's pin of a handover's recipient** (DevOps plan 0.3, on a Mac). A handover locks a login for the key that
/// the hub names as the receiving machine's, and a hub that is broken into could name a key of its own. So a vault whose
/// protected configuration holds the owner's public keys (`owner_keys`, with the fleet's id in `fleet`) locks a login
/// only for a key that the owner signed a pin of: the statement and the signature that the hub carries beside the job
/// (`pin`), checked here with those keys exactly as `vault.py` checks them on a Linux server (`owner_pinned`,
/// `owner_statement`, `owner_signed`).
///
/// Only root writes the protected configuration (`install.py --owner-keys-only`), and nothing that the hub sends changes
/// it. A configuration without the owner's keys checks nothing yet, and such a Mac hands over as it did before: on
/// 12 November 2026 no Mac's configuration held the keys, and this check must not stop a handover there. A Linux broker
/// without the keys refuses every handover instead.
public enum VaultOwnerPin {
    /// The most owner keys that may sign, as `vault.py` OWNER_KEYS.
    static let mostKeys = 8

    /// The statement and the signature of a pin, as the hub carries them beside a handover job.
    public struct Signed: Sendable, Equatable {
        public let statement: String
        public let signature: String

        public init(statement: String, signature: String) {
            self.statement = statement; self.signature = signature
        }

        /// The hub's `pin`: an object with the two texts. JSON null, a missing field or any other shape is no pin, so a
        /// vault without the owner's keys reads such a job as it did before.
        init?(_ value: Any?) {
            guard let fields = value as? [String: Any], let statement = fields["statement"] as? String,
                  let signature = fields["signature"] as? String else { return nil }
            self.init(statement: statement, signature: signature)
        }
    }

    /// One owner key: the standard base64, padded, of 65 bytes 04 || X || Y (CryptoKit's `x963Representation`) that is
    /// a point of P-256. Nil for anything else.
    static func key(_ text: String) -> P256.Signing.PublicKey? {
        guard let raw = Data(base64Encoded: text), raw.base64EncodedString() == text, raw.count == 65, raw.first == 4
        else { return nil }
        return try? P256.Signing.PublicKey(x963Representation: raw)
    }

    /// True when `keys` are the owner's keys of a protected configuration: 1 to `mostKeys` valid keys.
    static func validKeys(_ keys: [String]) -> Bool {
        (1...mostKeys).contains(keys.count) && keys.allSatisfy { key($0) != nil }
    }

    /// Refuses a handover unless the owner signed a pin of the recipient that the hub named for it, when this vault's
    /// configuration holds the owner's keys. Without them it refuses nothing.
    public static func check(_ job: VaultJob, configuration: VaultConfiguration) throws {
        guard let keys = configuration.ownerKeys, let fleet = configuration.fleet else { return }
        guard let pin = job.pin else { throw VaultFailure.ownerPinMissing }
        guard try recipient(of: pin, keys: keys, fleet: fleet) == job.recipient else { throw VaultFailure.ownerPinOther }
    }

    /// The recipient that a valid pin names: a statement in its canonical form with exactly the fields of a pin, for this
    /// fleet, and a signature of one of `keys` over its UTF-8 bytes.
    static func recipient(of pin: Signed, keys: [String], fleet: String) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(pin.statement.utf8)) as? [String: Any],
              Set(object.keys) == ["v", "kind", "fleet", "machine", "recipient", "at"],
              VaultRequest.integer(object["v"]) == 1,
              let at = VaultRequest.integer(object["at"]), at >= 0,
              object["kind"] as? String == "pin",
              let said = object["fleet"] as? String,
              let machine = object["machine"] as? String,
              whole(machine, "[a-z][a-z0-9-]{0,62}"),
              let recipient = object["recipient"] as? String,
              whole(recipient, "age1[0-9a-z]{58}"),
              canonical(["v": .number(1), "kind": .text("pin"), "fleet": .text(said), "machine": .text(machine),
                         "recipient": .text(recipient), "at": .number(at)]) == pin.statement,
              said == fleet,
              signed(pin.statement, signature: pin.signature, keys: keys) else { throw VaultFailure.ownerPinInvalid }
        return recipient
    }

    /// True when all of `text` matches `pattern`, as vault.py's `fullmatch`: ICU's `$` also matches before one final line
    /// break, so the pattern is anchored with `\A` and `\z` instead.
    static func whole(_ text: String, _ pattern: String) -> Bool {
        text.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
    }

    /// True when one of `keys` signed exactly these statement bytes: the signature is the standard base64, padded, of the
    /// DER form (CryptoKit's `derRepresentation`), over SHA-256 of the statement's UTF-8 bytes.
    static func signed(_ statement: String, signature: String, keys: [String]) -> Bool {
        guard let raw = Data(base64Encoded: signature), raw.base64EncodedString() == signature,
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: raw) else { return false }
        let bytes = Data(statement.utf8)
        return keys.contains { key($0)?.isValidSignature(parsed, for: bytes) == true }
    }

    /// One value of a statement: text or a whole number, as the owner's app writes them (`OwnerStatement` in FleetCore).
    enum Value: Equatable { case text(String), number(Int) }

    /// The canonical JSON of a flat object, the one text that the owner's app signs and `vault.py` checks: Python's
    /// `json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)`. The same spelling as the app's
    /// `OwnerStatement.canonical`, which this target does not import.
    static func canonical(_ fields: [String: Value]) -> String {
        let keys = fields.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        let members = keys.map { key -> String in
            switch fields[key]! {
            case .text(let text): return quoted(key) + ":" + quoted(text)
            case .number(let number): return quoted(key) + ":" + String(number)
            }
        }
        return "{" + members.joined(separator: ",") + "}"
    }

    /// One string as Python's encoder writes it with `ensure_ascii=False`.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
