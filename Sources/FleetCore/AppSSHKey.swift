#if os(macOS)
import Foundation
import SystemConfiguration

/// **The app's own SSH key** (the onboarding of 4 November 2026): one ed25519 key, made once on this Mac with no
/// passphrase, at `~/.ssh/founderizer_ed25519`, whose comment says which Mac it is (`founderizer@<this Mac's name>`).
///
/// The owner's own keys stay his: the app never opens, copies or sends one (`InstallPlan`). This key is the app's,
/// and it reaches a server one way only: `PasswordOnce` appends its public half to the account it logged in to, with
/// the password the owner gave once. From then on the install reaches that server with this key alone
/// (`IdentitiesOnly`), and until then it goes the way it always went: this Mac's SSH agent and keys, or the host's
/// entry in `~/.ssh/config`. Like the owner's keys, it is a file that `ssh` reads, and this app reads only its public
/// half.
public enum AppSSHKey {
    public static let name = "founderizer_ed25519"

    public enum Failure: LocalizedError, Equatable, Sendable {
        case notMade(String)
        public var errorDescription: String? {
            switch self { case .notMade(let says): return String(l10n: "This Mac could not make its own SSH key: \(says)") }
        }
    }

    /// The private key's path: `~/.ssh/founderizer_ed25519`, or the same name in `folder`.
    public static func path(in folder: URL = InstallTarget.keyFolder) -> String {
        folder.appendingPathComponent(name).path
    }

    /// The public key's line ("ssh-ed25519 AAAA… founderizer@Studio"), or nil while there is none, or none that is one.
    public static func publicLine(in folder: URL = InstallTarget.keyFolder) -> String? {
        guard let text = try? String(contentsOfFile: path(in: folder) + ".pub", encoding: .utf8) else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^ssh-ed25519 [A-Za-z0-9+/]+={0,2}( [^\\n]*)?$"
        return line.range(of: pattern, options: .regularExpression) != nil ? line : nil
    }

    /// `founderizer@<this Mac's name>`, in the letters a host name has.
    public static func comment(_ macName: String) -> String {
        let word = macName.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return "founderizer@" + (word.isEmpty ? "mac" : String(word.prefix(63)))
    }

    /// This Mac's own name on its network (System Settings, Sharing), which needs no lookup.
    public static func macName() -> String {
        (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? ProcessInfo.processInfo.hostName
    }

    /// **The public line, with the key made first when this Mac has none**: `ssh-keygen` writes both halves, the
    /// private one of mode 600, and nothing here reads it. A key that is there already is kept as it is, its mode put
    /// right where it drifted (`ssh` refuses a private key that others may read), and a public half that went missing
    /// is written again from it. Two makers at once leave one key: `ssh-keygen` refuses a file that is there, and the
    /// one that lost reads the other's.
    public static func make(in folder: URL = InstallTarget.keyFolder, macName: String = AppSSHKey.macName(),
                            keygen: String = "/usr/bin/ssh-keygen", run: ShellRunner = Shell.local) async throws -> String {
        let key = path(in: folder)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        if !FileManager.default.fileExists(atPath: key) {
            let made = try await run(keygen, ["-q", "-t", "ed25519", "-N", "", "-C", comment(macName), "-f", key], nil, 60)
            if !made.ok && !FileManager.default.fileExists(atPath: key) {
                throw Failure.notMade(made.lines.last ?? String(l10n: "ssh-keygen answered \(Int(made.status))."))
            }
        }
        _ = chmod(key, 0o600)
        if let line = publicLine(in: folder) { return line }
        let derived = try await run(keygen, ["-y", "-f", key], nil, 60)
        let line = derived.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard derived.ok, line.hasPrefix("ssh-ed25519 ") else {
            throw Failure.notMade(String(l10n: "\(key) is not a key it can read."))
        }
        // `-y` gives the key without its comment where the file has none of its own.
        let full = line.split(separator: " ").count >= 3 ? line : line + " " + comment(macName)
        try (full + "\n").write(toFile: key + ".pub", atomically: true, encoding: .utf8)
        guard let written = publicLine(in: folder) else { throw Failure.notMade(String(l10n: "\(key).pub could not be written.")) }
        return written
    }
}
#endif
