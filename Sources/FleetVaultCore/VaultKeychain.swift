import Foundation
import LocalAuthentication
import Security

public final class VaultKeychain: @unchecked Sendable {
    private let service = "local.agent-fleet.vault"
    private let group = "6EBZ756H9Q.local.agent-fleet.vault"
    private let agent: String
    public init(agent: String) { self.agent = agent }

    func read(_ item: String) throws -> Data {
        guard let data = try readIfPresent(item) else { throw VaultFailure.keychain }
        return data
    }

    func readIfPresent(_ item: String) throws -> Data? {
        let context = LAContext(); context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true, kSecAttrAccessGroup as String: group,
            kSecAttrService as String: service, kSecAttrAccount as String: "\(agent).\(item)",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = value as? Data, !data.isEmpty else { throw VaultFailure.keychain }
        return data
    }

    // Called only after owner authentication in the helper's local settings window.
    public func save(token: String) throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.utf8.count <= 4096, !token.contains("\n"), !token.contains("\0") else {
            throw VaultFailure.keychain
        }
        try save(Data(token.utf8), item: "token")
    }

    func save(_ data: Data, item: String) throws {
        // No legacy ACL or approval dialog. The OS checks the provisioned access-group entitlement.
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true, kSecAttrAccessGroup as String: group,
            kSecAttrService as String: service, kSecAttrAccount as String: "\(agent).\(item)"]
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false]
        var add = key; add.merge(values) { _, new in new }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || (status == errSecDuplicateItem &&
            SecItemUpdate(key as CFDictionary, values as CFDictionary) == errSecSuccess) else {
            throw VaultFailure.keychain
        }
    }

    public var hasToken: Bool { (try? read("token")) != nil }

    func remove(_ item: String) throws {
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true, kSecAttrAccessGroup as String: group,
            kSecAttrService as String: service, kSecAttrAccount as String: "\(agent).\(item)"]
        let status = SecItemDelete(key as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultFailure.keychain }
    }
}
