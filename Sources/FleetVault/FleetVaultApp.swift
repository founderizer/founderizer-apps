import AppKit
import Darwin
import FleetVaultCore
import SwiftUI

@MainActor @Observable final class VaultSettings {
    var message = "Starting vault…"
    var ready = false
    var saving = false
    var publicKey = ""
    var configured = false
    private var config: VaultConfiguration?
    private var socket: VaultSocket?

    init() {
        protectProcess()
        do {
            try VaultBroker.verifySignature()
            let configuration = try VaultBroker.loadConfiguration()
            config = configuration
            configured = true
            let broker = VaultBroker(configuration: configuration)
            let socket = VaultSocket(configuration: configuration, broker: broker)
            try socket.start(); self.socket = socket
            // The old items of the store that this vault opened before: no code uses them, so they go. A delete that
            // fails is tried again at the next start.
            _ = VaultOldItems.removeWorkerItems(agent: configuration.agent)
            refresh()
        } catch { message = (error as? VaultFailure)?.rawValue ?? "Founderizer Vault could not start." }
    }

    private func refresh() {
        guard let config else { return }
        let keychain = VaultKeychain(agent: config.agent)
        let identity = VaultIdentity(keychain: keychain, programs: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers"))
        publicKey = (try? identity.recipient()) ?? ""
        // The first request of the broker makes the keys and an empty store, so this window only reads them.
        ready = VaultStoreSetup.isOpen(agent: config.agent) && !publicKey.isEmpty
        message = ready ? "Vault ready for \(config.agent). It opens this fleet’s own store."
                        : "This Mac’s own store is not open yet. Fleet Vault makes it at the vault’s first request."
    }

    /// Makes the handover key and an empty store, and keeps both if they are there. The broker does the same at its
    /// first request, so this is only for an owner who opens the window first.
    func openStore() async {
        guard let config, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let agent = config.agent
            try await Task.detached { try VaultStoreSetup.open(agent: agent) }.value
            refresh()
        } catch { message = (error as? VaultFailure)?.rawValue ?? "This Mac’s own store was not made." }
    }
}

/// The same protection for every mode of this program, before any vault code runs.
private func protectProcess() {
    // Libraries must not inherit proxy, trace, TLS or debug settings from an agent.
    for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("RUST_") ||
        key.hasPrefix("BWS_") || key.hasPrefix("SSL_") || key.lowercased().contains("proxy") {
        unsetenv(key)
    }
    setenv("RUST_LOG", "off", 1)
    signal(SIGPIPE, SIG_IGN)
    var limit = rlimit(rlim_cur: 0, rlim_max: 0); setrlimit(RLIMIT_CORE, &limit)
}

/// One program, four modes. With the argument `writer`, launchd started it on the owner's Mac, where it was the
/// writer of the app's old Add secret: it deletes that writer's items and ends (`VaultOldItems`). With `store-put` or
/// `store-list` the owner saves one login or key in this machine's own store, or reads the names that are in it, as
/// `vault.py store-put` and `store-list` do on Linux: it prints one line of JSON and ends. Else it shows its window:
/// one line where the configuration is the owner's, and the worker's vault everywhere else.
@main enum FleetVaultMain {
    /// The worker's vault, which opens its socket when it is made. The window shows it.
    @MainActor static let worker = VaultSettings()

    @MainActor static func main() {
        protectProcess()
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "writer" { writer() }
        if let first = arguments.first, ["store-put", "store-list"].contains(first) { store(arguments) }
        if VaultOldItems.isOwnerMac { OwnerVaultApp.main() } else {
            // The worker's socket opens before AppKit's launch, which macOS can hold for hours: after a macOS update on
            // 4 November 2026, Setup Assistant held a Mac Studio's session, the launch waited for it, and the agents got
            // no answer. Browser work, which needs the main thread, waits for the end of the launch (`VaultBrowser`).
            _ = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil,
                                                       queue: nil) { _ in VaultBrowser.launchEnded() }
            _ = worker
            FleetVaultApp.main()
        }
    }

    /// `writer`, which the owner's LaunchAgent `com.agentfleet.vault.writer` starts: one cleanup of the old writer's
    /// Keychain items. It reads no item, it is safe to run again, and it prints one line. Status 0 when the items are
    /// gone, so the vault's updater then takes that LaunchAgent away (`Vault/update.zsh`).
    static func writer() -> Never {
        func end(_ text: String, _ code: Int32) -> Never {
            (code == 0 ? FileHandle.standardOutput : FileHandle.standardError).write(Data((text + "\n").utf8))
            exit(code)
        }
        guard (try? VaultBroker.verifySignature()) != nil else {
            end("This program is not the signed Founderizer Vault, so it changed nothing.", 1)
        }
        guard VaultOldItems.removeWriterItems() else {
            end("Founderizer Vault could not delete the items of its old writer. The vault's updater tries again.", 1)
        }
        end("Founderizer Vault: the items of its old writer are not in this Mac's Keychain any more.", 0)
    }

    /// `store-put --title "<name>" [--note "<line>"]`, with the item as JSON on **standard input**, and
    /// `store-list`. The value is read once, goes into the store, and stands in no argument and in no answer.
    static func store(_ arguments: [String]) -> Never {
        func end(_ text: String, _ code: Int32) -> Never {
            (code == 0 ? FileHandle.standardOutput : FileHandle.standardError).write(Data((text + "\n").utf8))
            exit(code)
        }
        func printed(_ object: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
                  let text = String(data: data, encoding: .utf8) else { return "{\"ok\": false}" }
            return text
        }
        do {
            try VaultBroker.verifySignature()
            var named: [String: String] = [:]
            var rest = arguments.dropFirst()
            while let name = rest.first, name.hasPrefix("--") {
                guard let value = rest.dropFirst().first else { throw VaultFailure.request }
                named[String(name.dropFirst(2))] = value
                rest = rest.dropFirst(2)
            }
            guard rest.isEmpty, Set(named.keys).isSubset(of: ["title", "note"]) else { throw VaultFailure.request }
            if arguments[0] == "store-list" {
                guard named.isEmpty else { throw VaultFailure.request }
                end(printed(try VaultStoreCommand.list()), 0)
            }
            guard let title = named["title"] else {
                end("Give the item's name: store-put --title \"<name>\", and the item as JSON on standard input.", 2)
            }
            let item = FileHandle.standardInput.readDataToEndOfFile()
            end(printed(try VaultStoreCommand.put(title: title, note: named["note"] ?? "", item: item)), 0)
        } catch {
            end(printed(["ok": false, "error": (error as? VaultFailure)?.rawValue ?? "This machine's vault store was not used."]), 1)
        }
    }
}

/// The owner's Mac runs no agent, and the owner adds secrets in Founderizer, so its vault has nothing to do. The
/// window says so in one line, with no field and no button.
struct OwnerVaultApp: App {
    var body: some Scene {
        WindowGroup("Founderizer Vault") {
            VStack(alignment: .leading, spacing: 14) {
                Label("Founderizer Vault", systemImage: "lock.shield").font(.system(size: 17, weight: .semibold))
                Text("This Mac’s vault has nothing to do: you add secrets in Founderizer.").font(.system(size: 12))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20).frame(width: 430).preferredColorScheme(.dark)
        }.windowResizability(.contentSize)
    }
}

struct FleetVaultApp: App {
    @State private var settings = FleetVaultMain.worker
    var body: some Scene {
        WindowGroup("Founderizer Vault") {
            VStack(alignment: .leading, spacing: 14) {
                Label("Founderizer Vault", systemImage: "lock.shield").font(.system(size: 17, weight: .semibold))
                Text(settings.message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.configured {
                    Text("This Mac keeps the fleet’s own store: one locked file of this helper. Only Fleet Vault can open it. "
                         + "Add a secret from Founderizer.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !settings.ready {
                        Button("Set up this machine’s vault") { Task { await settings.openStore() } }.disabled(settings.saving)
                    }
                }
                if !settings.publicKey.isEmpty {
                    Divider()
                    Text("Public handover key").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(settings.publicKey).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
                if settings.ready {
                    Divider()
                    Text("New logins").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("This Mac can save a login that an agent makes, when Founderizer permits it. Its own store needs no setting.")
                        .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(20).frame(width: 430).preferredColorScheme(.dark)
        }.windowResizability(.contentSize)
    }
}
