import AppKit
import Darwin
import FleetVaultCore
import LocalAuthentication
import SwiftUI

@MainActor @Observable final class VaultSettings {
    var message = "Starting vault…"
    var token = ""
    var ready = false
    var saving = false
    var publicKey = ""
    var configured = false
    var importExistingKey = true
    /// This Mac's one-time setup for new logins that an agent makes (`create`): off until the owner turns it on.
    var creates = false
    var project = ""
    /// Which store this Mac opens. The fleet's own needs no token and no project: it makes its key and an empty
    /// store itself, and the owner adds a secret from Founderizer.
    var backend = VaultBackend.bitwarden
    private var config: VaultConfiguration?
    private var socket: VaultSocket?

    init() {
        protectProcess()
        do {
            try VaultBroker.verifySignature()
            let configuration = try VaultBroker.loadConfiguration()
            config = configuration
            configured = true
            backend = configuration.backend
            let broker = VaultBroker(configuration: configuration)
            let socket = VaultSocket(configuration: configuration, broker: broker)
            try socket.start(); self.socket = socket
            refresh()
        } catch { message = (error as? VaultFailure)?.rawValue ?? "Founderizer Vault could not start." }
    }

    private func refresh() {
        guard let config else { return }
        let keychain = VaultKeychain(agent: config.agent)
        let identity = VaultIdentity(keychain: keychain, programs: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers"))
        publicKey = (try? identity.recipient()) ?? ""
        if backend == .store {
            // The first request of the broker makes the keys and an empty store, so this window only reads them.
            let store = VaultStoreSetup.isOpen(agent: config.agent)
            ready = store && !publicKey.isEmpty
            creates = store
            message = ready ? "Vault ready for \(config.agent). It opens this fleet’s own store."
                            : "This Mac’s own store is not open yet. Fleet Vault makes it at the vault’s first request."
            return
        }
        ready = keychain.hasToken && !publicKey.isEmpty
        creates = VaultCreateSetup.isOn(agent: config.agent)
        message = ready ? "Vault ready for \(config.agent)" : "Add this machine’s Bitwarden token."
    }

    /// Lets this Mac save new logins into one Bitwarden project, or stops that. The machine's token must have write
    /// access to the project in Bitwarden. An agent also needs the owner's permission in Fleet for each save.
    func setCreates(_ on: Bool) async {
        guard let config, ready, !saving, !on || !project.isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            guard try await LAContext().evaluatePolicy(.deviceOwnerAuthentication,
                    localizedReason: on ? "Let this Mac save new logins in Bitwarden." : "Stop this Mac from saving new logins.") else { return }
            let agent = config.agent, region = try config.bitwardenRegion(), project = project
            try await Task.detached {
                if on { try VaultCreateSetup.turnOn(agent: agent, project: project, region: region) } else { try VaultCreateSetup.turnOff(agent: agent) }
            }.value
            self.project = ""
            refresh()
        } catch { message = (error as? VaultFailure)?.rawValue ?? "The setting was not changed. Owner authentication is required." }
    }

    func save() async {
        guard let config, !token.isEmpty, !saving else { return }
        saving = true
        defer { saving = false; token = "" }
        let context = LAContext()
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
                    localizedReason: "Save this machine’s Founderizer vault token in Keychain.") else { return }
            var importedKey: Data?
            if publicKey.isEmpty && importExistingKey {
                let panel = NSOpenPanel()
                panel.title = "Import this machine’s handover key"
                panel.message = "Select age.key. Founderizer Vault keeps the existing public key."
                panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                panel.showsHiddenFiles = true
                panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fleet")
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, (1...8192).contains(size) else { throw VaultFailure.handover }
                importedKey = try readFile(url)
            }
            try await persist(token: token, key: importedKey, configuration: config)
        } catch { message = (error as? VaultFailure)?.rawValue ?? "The token was not saved. Owner authentication is required." }
    }

    /// A store Mac has no token to save: this makes the handover key and an empty store, and keeps both if they are
    /// there. The broker does the same at its first request, so this is only for an owner who opens the window first.
    func openStore() async {
        guard let config, backend == .store, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let agent = config.agent
            try await Task.detached { try VaultStoreSetup.open(agent: agent) }.value
            refresh()
        } catch { message = (error as? VaultFailure)?.rawValue ?? "This Mac’s own store was not made." }
    }

    func importMachineVault() async {
        guard let config, !saving else { return }
        saving = true
        defer { saving = false; token = "" }
        do {
            guard try await LAContext().evaluatePolicy(.deviceOwnerAuthentication,
                    localizedReason: "Move this machine’s Founderizer vault into the protected Keychain.") else { return }
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fleet")
            let data = try readFile(directory.appendingPathComponent("bws-token"))
            guard let token = String(data: data, encoding: .utf8) else { throw VaultFailure.keychain }
            let key = try readFile(directory.appendingPathComponent("age.key"))
            try await persist(token: token, key: key, configuration: config)
            message = "Imported for \(config.agent). Ready for the worker switch."
        } catch { message = (error as? VaultFailure)?.rawValue ?? "The existing vault was not imported." }
    }

    private func readFile(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw VaultFailure.keychain }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 8192,
              let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 8193),
              data.count <= 8192 else { throw VaultFailure.keychain }
        return data
    }

    private func persist(token: String, key: Data?, configuration: VaultConfiguration) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Data(token.utf8), region = try configuration.bitwardenRegion()
        try await Task.detached { try VaultBroker.validateToken(bytes, region: region) }.value
        let keychain = VaultKeychain(agent: configuration.agent)
        let identity = VaultIdentity(keychain: keychain, programs: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers"))
        if let key { try identity.importIdentity(key) } else { try identity.createIfMissing() }
        try keychain.save(token: token)
        refresh()
    }
}

/// The same protection for every mode of this program, before any vault code runs.
private func protectProcess() {
    // Third-party libraries must not inherit proxy, trace, TLS or debug settings from an agent.
    for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("RUST_") ||
        key.hasPrefix("BWS_") || key.hasPrefix("SSL_") || key.lowercased().contains("proxy") {
        unsetenv(key)
    }
    setenv("RUST_LOG", "off", 1)
    signal(SIGPIPE, SIG_IGN)
    var limit = rlimit(rlim_cur: 0, rlim_max: 0); setrlimit(RLIMIT_CORE, &limit)
}

/// One program, five modes. With the argument `writer`, launchd started it for Fleet's Add secret on the owner's
/// Mac: it serves its Mach service and shows no window. With `store-put` or `store-list` the owner saves one login
/// or key in this machine's own store, or reads the names that are in it, as `vault.py store-put` and `store-list`
/// do on Linux: it prints one line of JSON and ends. Else it shows its window: the owner's one-time setup of the
/// writer where the configuration is an owner's, and the worker's vault as before everywhere else.
@main enum FleetVaultMain {
    /// The worker's vault, which opens its socket when it is made. The window shows it.
    @MainActor static let worker = VaultSettings()

    @MainActor static func main() {
        protectProcess()
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "writer" { VaultWriterService.run() }
        if let first = arguments.first, ["store-put", "store-list"].contains(first) { store(arguments) }
        if (try? VaultWriterConfiguration.load()) != nil { WriterSetupApp.main() } else {
            // The worker's socket opens before AppKit's launch, which macOS can hold for hours: after a macOS update on
            // 4 November 2026, Setup Assistant held a Mac Studio's session, the launch waited for it, and the agents got
            // no answer. Browser work, which needs the main thread, waits for the end of the launch (`VaultBrowser`).
            _ = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil,
                                                       queue: nil) { _ in VaultBrowser.launchEnded() }
            _ = worker
            FleetVaultApp.main()
        }
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

/// The owner's Mac: the Bitwarden access token that can write, and the project that gets the new logins. The owner
/// enters them here once, after owner authentication. Fleet never gets them.
@MainActor @Observable final class WriterSettings {
    var message = "Starting vault…"
    var token = ""
    var project = ""
    var ready = false
    var saving = false
    private var configuration: VaultWriterConfiguration?

    init() {
        protectProcess()
        do {
            try VaultBroker.verifySignature()
            configuration = try VaultWriterConfiguration.load()
            refresh()
        } catch { message = (error as? VaultFailure)?.rawValue ?? "Founderizer Vault could not start." }
    }

    var configured: Bool { configuration != nil }

    var backend: VaultBackend { configuration?.backend ?? .bitwarden }

    private func refresh() {
        ready = VaultWriterSetup.isDone(backend: backend)
        if backend == .store {
            message = ready ? "Ready. Founderizer adds logins into this fleet’s own store on this Mac."
                            : "This Mac’s own store is not open yet. It is made at the first login that Founderizer adds."
            return
        }
        ready = VaultWriterSetup.isDone
        message = ready ? "Ready. Founderizer can add logins on this Mac." : "Add the Bitwarden access token that can write, and the project’s ID."
    }

    func save() async {
        guard let configuration, !token.isEmpty, !project.isEmpty, !saving else { return }
        saving = true
        defer { saving = false; token = "" }
        do {
            guard try await LAContext().evaluatePolicy(.deviceOwnerAuthentication,
                    localizedReason: "Save the Bitwarden write token of Founderizer in Keychain.") else { return }
            guard let region = configuration.region else { throw VaultFailure.configuration }
            let token = token, project = project
            try await Task.detached { try VaultWriterSetup.save(token: token, project: project, region: region) }.value
            self.project = ""
            refresh()
        } catch { message = (error as? VaultFailure)?.rawValue ?? "The token was not saved. Owner authentication is required." }
    }
}

struct WriterSetupApp: App {
    @State private var settings = WriterSettings()
    var body: some Scene {
        WindowGroup("Founderizer Vault") {
            VStack(alignment: .leading, spacing: 14) {
                Label("Founderizer Vault", systemImage: "lock.shield").font(.system(size: 17, weight: .semibold))
                Text(settings.message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.backend == .store {
                    Text("This Mac keeps the fleet’s own store: one locked file of this helper, with no Bitwarden account. "
                         + "Only Founderizer Vault can open it, and there is nothing to enter here.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    SecureField("Bitwarden write token", text: $settings.token).textFieldStyle(.roundedBorder)
                        .disabled(settings.saving || !settings.configured)
                    TextField("Bitwarden project ID", text: $settings.project).textFieldStyle(.roundedBorder)
                        .disabled(settings.saving || !settings.configured)
                    HStack {
                        Text("Only Founderizer Vault can read the saved token. Founderizer sends it the logins that you add.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(settings.ready ? "Replace" : "Save") { Task { await settings.save() } }
                            .disabled(settings.token.isEmpty || settings.project.isEmpty || settings.saving || !settings.configured)
                    }
                }
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
                if settings.backend == .store {
                    Text("This Mac keeps the fleet’s own store: one locked file of this helper, with no Bitwarden account. "
                         + "Only Fleet Vault can open it. Add a secret from Founderizer.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !settings.ready {
                        Button("Set up this machine’s vault") { Task { await settings.openStore() } }.disabled(settings.saving)
                    }
                } else {
                if settings.configured && !settings.ready {
                    Button("Import this machine’s vault") { Task { await settings.importMachineVault() } }
                        .disabled(settings.saving)
                    Divider()
                }
                SecureField("Bitwarden machine token", text: $settings.token).textFieldStyle(.roundedBorder)
                    .disabled(settings.saving || !settings.configured)
                if settings.configured && settings.publicKey.isEmpty {
                    Toggle("Import existing handover key", isOn: $settings.importExistingKey)
                        .font(.system(size: 11)).disabled(settings.saving)
                    if !settings.importExistingKey {
                        Text("A new key cannot open earlier handovers.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Only this helper can read the saved token.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { Task { await settings.save() } }
                        .disabled(settings.token.isEmpty || settings.saving || !settings.configured)
                }
                }
                if !settings.publicKey.isEmpty {
                    Divider()
                    Text("Public handover key").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(settings.publicKey).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
                if settings.ready && settings.backend == .store {
                    Divider()
                    Text("New logins").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("This Mac can save a login that an agent makes, when Founderizer permits it. Its own store needs no setting.")
                        .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                } else if settings.ready {
                    Divider()
                    Text("New logins").font(.system(size: 11)).foregroundStyle(.secondary)
                    if settings.creates {
                        HStack {
                            Text("This Mac can save a login that an agent makes, when Founderizer permits it.").font(.system(size: 11))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Stop") { Task { await settings.setCreates(false) } }.disabled(settings.saving)
                        }
                    } else {
                        HStack {
                            TextField("Bitwarden project ID", text: $settings.project).textFieldStyle(.roundedBorder).disabled(settings.saving)
                            Button("Allow") { Task { await settings.setCreates(true) } }.disabled(settings.project.isEmpty || settings.saving)
                        }
                        Text("Off. With a project, this Mac can save new logins there. Its token needs write access to that project in Bitwarden.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(20).frame(width: 430).preferredColorScheme(.dark)
        }.windowResizability(.contentSize)
    }
}
