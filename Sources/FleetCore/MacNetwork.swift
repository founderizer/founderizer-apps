#if os(macOS)
import Foundation

/// Tailscale on the owner's **own** Mac, which nothing in the product covered: their Mac has to be on the private
/// network for this app to reach the hub at all, and until now it was expected to be there already.
///
/// This Mac is read, and when Tailscale is missing the app downloads Tailscale's own installer, **checks that
/// Tailscale signed it**, and hands it to the macOS installer for the person to approve. Four clicks cannot be
/// taken away from them, and they are Apple's, not ours:
///
///   1. the installer's own Continue and Install, with an **administrator password**, because a package that
///      carries a system extension cannot be installed quietly without a device-management profile;
///   2. **Allow** for the system extension, in System Settings → Privacy & Security, once Tailscale has been
///      opened — the app registers the extension, the package does not;
///   3. **Allow** for the VPN configuration, the first time Tailscale builds the tunnel;
///   4. **signing in**, at whichever identity provider their Tailscale account uses.
///
/// Their Mac signs in **as them**, and is never given a key of ours: a key would tag it, and a tag takes a
/// person's own identity off a device. As themselves it is also a user device, which Tailscale does not charge for.
public enum MacNetwork {
    /// Tailscale's own package for the standalone variant, which is the one Tailscale recommends and which needs
    /// no Apple ID.
    public static let download = URL(string: "https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg")!
    /// Who must have signed that package. Anything else is not opened.
    public static let signer = "Developer ID Installer: Tailscale Inc. (W5364U7YZB)"
    /// What Apple's own check says about a package Tailscale sent for notarization.
    public static let notarized = "Notarization: trusted by the Apple notary service"

    /// Where a `tailscale` command can be on a Mac: the standalone variant's own link, the command inside either
    /// app bundle, and Homebrew's.
    public static let commands = ["/usr/local/bin/tailscale",
                                  "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                                  "/opt/homebrew/bin/tailscale",
                                  "/usr/bin/tailscale"]

    /// What this Mac is, as far as the private network goes.
    public struct Standing: Equatable, Sendable {
        /// The one thing the screen has to say.
        public enum Step: String, Equatable, Sendable, CaseIterable {
            /// No Tailscale on this Mac at all.
            case notInstalled
            /// Tailscale is here and nobody has signed in.
            case notSignedIn
            /// Tailscale is here and signed in, and the tunnel is not up.
            case notConnected
            /// This Mac is on the private network.
            case connected
        }
        public let step: Step
        /// This Mac's own address on the private network (100.64.0.0/10), when it has one.
        public let address: String?
        /// The network it is on, as Tailscale names it.
        public let tailnet: String?
        /// Tailscale's own word for its state, so a screen never has to invent one.
        public let says: String?

        public init(step: Step, address: String? = nil, tailnet: String? = nil, says: String? = nil) {
            self.step = step; self.address = address; self.tailnet = tailnet; self.says = says
        }

        public var isConnected: Bool { step == .connected }

        /// **This Mac's standing as one mark.** The owner, 20 October 2026: "not even sentences, just a check or a
        /// cross, and on hover probably show the detail?" Whether this Mac is on the network is a yes-or-no fact,
        /// so the row answers with the mark and Tailscale's own words are behind it.
        public var mark: (state: MarkState, words: String) {
            switch step {
            case .connected: (.good, String(l10n: "On your network"))
            case .notInstalled: (.bad, String(l10n: "Not installed"))
            case .notSignedIn: (.bad, String(l10n: "Not signed in"))
            case .notConnected: (.bad, String(l10n: "Not connected"))
            }
        }
    }

    /// The `tailscale` command of this Mac, or nil when there is none.
    public static func command(exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) })
        -> String? {
        commands.first(where: exists)
    }

    /// Reads this Mac: whether Tailscale is installed, whether it is connected, and with which address.
    public static func read() async -> Standing {
        guard let command = command() else { return Standing(step: .notInstalled) }
        // The app's own binary is both the app and the command; this is what makes it answer as the command.
        let answer = try? await LocalShell.sh("TAILSCALE_BE_CLI=1 \(InstallPlan.quote(command)) status --json",
                                              timeout: 20)
        return reading(answer?.output ?? "")
    }

    /// The same answer out of `tailscale status --json`, so every step of this is proved without Tailscale.
    public static func reading(_ json: String) -> Standing {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["BackendState"] as? String else {
            return Standing(step: .notSignedIn)
        }
        let own = object["Self"] as? [String: Any]
        let address = (own?["TailscaleIPs"] as? [String])?.first { ClaimCode.isPrivateAddress($0) }
        let tailnet = (object["CurrentTailnet"] as? [String: Any])?["Name"] as? String
        let step: Standing.Step
        switch state {
        case "Running": step = address == nil ? .notConnected : .connected
        case "NeedsLogin", "NoState": step = .notSignedIn
        default: step = .notConnected
        }
        return Standing(step: step, address: address, tailnet: tailnet?.isEmpty == false ? tailnet : nil, says: state)
    }

    /// **Which device of the private network a host is**, as this Mac's own Tailscale says: the name a machine has in
    /// Tailscale (the first label of its MagicDNS name, lower case), which is its name in Fleet too. The host is one
    /// of a device's Tailscale addresses, its MagicDNS name, or that name's first label. nil when no device of this
    /// Mac's network is that host, or Tailscale does not answer. A server's vault key is pinned only when this names the
    /// server: the address of a connection can come from the hub, and the hub's word alone pins nothing.
    public static func device(of host: String) async -> String? {
        guard let command = command() else { return nil }
        let answer = try? await LocalShell.sh("TAILSCALE_BE_CLI=1 \(InstallPlan.quote(command)) status --json", timeout: 20)
        return device(of: host, in: answer?.output ?? "")
    }

    /// This Mac's own `tailscale status --json`, or nil when Tailscale does not answer.
    public static func status() async -> String? {
        guard let command = command() else { return nil }
        guard let answer = try? await LocalShell.sh("TAILSCALE_BE_CLI=1 \(InstallPlan.quote(command)) status --json", timeout: 20),
              answer.ok else { return nil }
        return answer.output
    }

    /// The same answer out of `tailscale status --json`, so it is proved without Tailscale.
    public static func device(of host: String, in json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let wanted = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let peers = (object["Peer"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
        let names = ([object["Self"] as? [String: Any]].compactMap { $0 } + peers).compactMap { node -> String? in
            let full = ((node["DNSName"] as? String) ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard let name = full.split(separator: ".").first.map(String.init), !name.isEmpty else { return nil }
            let addresses = ((node["TailscaleIPs"] as? [String]) ?? []).map { $0.lowercased() }
            return addresses.contains(wanted) || wanted == full || wanted == name ? name : nil
        }
        return Set(names).count == 1 ? names.first : nil
    }

    /// Gets Tailscale's own installer, makes sure Tailscale signed it, and gives it to the macOS installer, which
    /// is where the person approves it. Nothing is installed by this app and no password is ever asked for here.
    ///
    /// The package goes in a folder of its own that nothing else writes to, and it is deleted if it is not
    /// Tailscale's.
    public static func install(open: @Sendable (URL) async -> Bool = MacNetwork.hand) async throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("founderizer-tailscale-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("Tailscale.pkg")
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForResource = 600
            let (temporary, response) = try await URLSession(configuration: configuration).download(from: download)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw MacNetworkError.cannotDownload(String(l10n: "Tailscale's own download page did not give the installer."))
            }
            try FileManager.default.moveItem(at: temporary, to: file)
        } catch let error as MacNetworkError {
            try? FileManager.default.removeItem(at: folder)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw MacNetworkError.cannotDownload(error.localizedDescription)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int ?? 0
        let report = try? await LocalShell.run("/usr/sbin/pkgutil", ["--check-signature", file.path], timeout: 120)
        guard size > 1_000_000, let report, report.ok, isTailscales(report.output) else {
            try? FileManager.default.removeItem(at: folder)
            throw MacNetworkError.notTailscales
        }
        guard await open(file) else {
            throw MacNetworkError.cannotOpen(file.path)
        }
        return file
    }

    /// What `pkgutil --check-signature` must say: Tailscale signed it, and Apple notarized it.
    public static func isTailscales(_ report: String) -> Bool {
        report.contains(signer) && report.contains(notarized)
    }

    /// Opens Tailscale, which is where a person signs in and where macOS asks them for the system extension.
    @discardableResult
    public static func openTailscale() async -> Bool {
        let answer = try? await LocalShell.run("/usr/bin/open", ["-a", "Tailscale"], timeout: 30)
        return answer?.ok == true
    }

    /// Hands a file to whatever macOS opens it with. For a package that is the macOS installer, and the person
    /// takes it from there.
    public static func hand(_ file: URL) async -> Bool {
        let answer = try? await LocalShell.run("/usr/bin/open", [file.path], timeout: 30)
        return answer?.ok == true
    }
}

public enum MacNetworkError: LocalizedError, Equatable, Sendable {
    case cannotDownload(String)
    case notTailscales
    case cannotOpen(String)

    public var errorDescription: String? {
        switch self {
        case .cannotDownload(let says): String(l10n: "Tailscale's installer could not be downloaded: \(says)")
        case .notTailscales:
            String(l10n: "That download is not signed by Tailscale, so this Mac did not open it. Nothing was installed.")
        case .cannotOpen(let path): String(l10n: "This Mac could not open \(path). Open it yourself to install Tailscale.")
        }
    }
}

#endif
