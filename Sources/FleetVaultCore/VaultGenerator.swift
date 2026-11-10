import Foundation
import Security

/// A new password for a login that the vault makes itself (`create`). The default and the limits here are choices
/// for new logins only. They are no rule for the passwords of the logins that exist.
enum VaultGenerator {
    struct Rules: Equatable, Sendable {
        var length = 24
        /// Some sites ask for a symbol.
        var symbols = false
        static let lengths = 8...128
        var isValid: Bool { Self.lengths.contains(length) }
    }

    static let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ", lower = "abcdefghijklmnopqrstuvwxyz", digits = "0123456789", symbols = "-_.!@#%+="

    /// A password with a capital letter, a small letter and a digit (and a symbol, when asked), each character with
    /// the same probability. `random` gives that many random bytes; a source that cannot give such a password in a
    /// fixed number of draws is refused.
    static func password(_ rules: Rules = Rules(), random: (Int) throws -> [UInt8] = secureBytes) throws -> String {
        guard rules.isValid else { throw VaultFailure.request }
        let classes = [upper, lower, digits] + (rules.symbols ? [symbols] : [])
        let alphabet = Array(classes.joined())
        let limit = 256 - 256 % alphabet.count          // a byte at or over the limit would favor the first characters
        for _ in 0..<32 {
            var result: [Character] = []
            for _ in 0..<32 where result.count < rules.length {
                for byte in try random(rules.length * 2) where Int(byte) < limit && result.count < rules.length {
                    result.append(alphabet[Int(byte) % alphabet.count])
                }
            }
            if result.count == rules.length, classes.allSatisfy({ part in result.contains(where: part.contains) }) { return String(result) }
        }
        throw VaultFailure.dependency
    }

    static func secureBytes(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw VaultFailure.dependency }
        return bytes
    }
}
