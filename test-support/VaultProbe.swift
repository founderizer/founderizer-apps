import Darwin
import Foundation

@main struct VaultProbe {
    static func main() throws {
        signal(SIGPIPE, SIG_IGN)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let sdk = try VaultBitwarden(libraryURL: root.appendingPathComponent("sdk-sm-0520690b9710af7a8b1e47aad776f002f369688f/target/release/libbitwarden_c.dylib"), region: "eu")
        do {
            _ = try sdk.login(token: Data("invalid-test-token".utf8), secretID: "12345678-1234-1234-1234-123456789012")
            fatalError("The SDK accepted an invalid test token")
        } catch VaultFailure.provider { print("SDK invalid-token refusal: PASS") }
        let programs = VaultPrograms(directory: root.appendingPathComponent("age"))
        let key = try programs.run("age-keygen", arguments: [])
        let recipient = try VaultIdentity.recipient(key)
        let derived = try programs.run("age-keygen", arguments: ["-y"], input: key)
        guard String(decoding: derived, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == recipient else {
            fatalError("Imported identity derivation failed")
        }
        print("age imported identity derivation: PASS")
        let test = Data("Fleet test payload; no account credentials".utf8)
        let encrypted = try programs.run("age", arguments: ["--armor", "--recipient", recipient], input: test)
        let decrypted = try programs.run("age", arguments: ["--decrypt", "--identity", "/dev/fd/3"], input: encrypted, identity: key)
        guard decrypted == test else { fatalError("The age pipe round trip failed") }
        print("age private-pipe round trip: PASS")
        let other = try programs.run("age-keygen", arguments: [])
        do {
            _ = try programs.run("age", arguments: ["--decrypt", "--identity", "/dev/fd/3"], input: encrypted, identity: other)
            fatalError("The wrong age identity was accepted")
        } catch VaultFailure.handover { print("age wrong-identity refusal: PASS") }
    }
}
