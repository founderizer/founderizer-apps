import Foundation
import LocalAuthentication
import Security

// Test-only executable. It can access only synthetic items in this fixed test namespace.
// Build a provisioned copy and an unentitled copy to test the OS access-group boundary.
let args = CommandLine.arguments
guard args.count == 3, ["write", "read", "delete"].contains(args[1]),
      UUID(uuidString: args[2]) != nil else { exit(2) }
let context = LAContext()
context.interactionNotAllowed = true
var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecUseDataProtectionKeychain as String: true,
    kSecAttrAccessGroup as String: "6EBZ756H9Q.local.agent-fleet.vault",
    kSecAttrService as String: "local.agent-fleet.vault.boundary-test",
    kSecAttrAccount as String: args[2],
    kSecUseAuthenticationContext as String: context]
let expected = Data("Synthetic Fleet boundary check".utf8)
let status: OSStatus
switch args[1] {
case "write":
    query[kSecValueData as String] = expected
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    query[kSecAttrSynchronizable as String] = false
    status = SecItemAdd(query as CFDictionary, nil)
case "read":
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess, result as? Data != expected { exit(3) }
default:
    status = SecItemDelete(query as CFDictionary)
}
print("\(args[1]): \(status)")
exit(status == errSecSuccess ? 0 : 1)
