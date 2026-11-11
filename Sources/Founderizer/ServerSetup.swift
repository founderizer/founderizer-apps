import AppKit
import FleetCore
import FleetSetupIPC
import Observation
import SwiftUI

@MainActor @Observable
final class ServerSetupSession {
    var configuration = ServerConfiguration()
    private(set) var timeline = SetupTimeline()
    private(set) var running = false
    private(set) var busy = false
    private(set) var available = false
    private(set) var error: String?
    /// The bundled executor, from `onboard.py version` (owner API 1.12 placement). The setup view does not read it.
    private(set) var executor: SetupExecutor?
    var hubReady = false
    private var connection: NSXPCConnection?
    private var poll: Task<Void, Never>?

    private func service(onError: @escaping @Sendable (Error) -> Void) -> FleetSetupServiceProtocol? {
        if connection == nil {
            let connection = NSXPCConnection(serviceName: SetupServiceID.name)
            connection.remoteObjectInterface = NSXPCInterface(with: FleetSetupServiceProtocol.self)
            connection.resume()
            self.connection = connection
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? FleetSetupServiceProtocol
    }

    func check() async {
        let status: (Bool, String) = await withCheckedContinuation { continuation in
            guard let service = service(onError: { _ in continuation.resume(returning: (false, "The local setup helper is unavailable.")) }) else {
                continuation.resume(returning: (false, "The local setup helper is unavailable.")); return
            }
            service.availability { available, detail in continuation.resume(returning: (available, detail)) }
        }
        available = status.0
        error = status.1.isEmpty ? nil : status.1
    }

    /// The bundled executor does not change while the app runs, so one good reading is enough.
    func checkExecutor() async {
        guard executor == nil else { return }
        let data: Data = await withCheckedContinuation { continuation in
            guard let service = service(onError: { _ in continuation.resume(returning: Data()) }) else {
                continuation.resume(returning: Data()); return
            }
            service.executorVersion { continuation.resume(returning: $0) }
        }
        executor = try? JSONDecoder().decode(SetupExecutor.self, from: data)
    }

    func resetIfComplete() {
        if timeline.result?.status == "ok" { reset() }
    }

    func reset() {
        guard !running, !busy else { return }
        poll?.cancel(); poll = nil
        let hub = configuration.hub
        configuration = ServerConfiguration(); configuration.hub = hub
        timeline = SetupTimeline(); error = nil
    }

    func start() async {
        guard !busy, !running, available, hubReady else { return }
        do { try configuration.validate() } catch { self.error = error.localizedDescription; return }
        busy = true; error = nil; timeline = SetupTimeline()
        let data = try! JSONEncoder().encode(configuration)
        let result: (Bool, String) = await withCheckedContinuation { continuation in
            guard let service = service(onError: { _ in continuation.resume(returning: (false, "The local setup helper disconnected.")) }) else {
                continuation.resume(returning: (false, "The local setup helper is unavailable.")); return
            }
            service.start(configuration: data) { ok, message in continuation.resume(returning: (ok, message)) }
        }
        busy = false; running = result.0; error = result.1.isEmpty ? nil : result.1
        if running { poll = Task { await read() } }
    }

    private func read() async {
        while !Task.isCancelled {
            let reply: (Data, Bool, String) = await withCheckedContinuation { continuation in
                guard let service = service(onError: { _ in continuation.resume(returning: (Data(), false, "Setup disconnected. Resume to check the server.")) }) else {
                    continuation.resume(returning: (Data(), false, "Setup disconnected.")); return
                }
                service.readEvents(after: timeline.sequence) { data, running, detail in continuation.resume(returning: (data, running, detail)) }
            }
            guard !Task.isCancelled else { return }
            do {
                let events = try JSONDecoder().decode([SetupEvent].self, from: reply.0)
                for event in events { try timeline.append(event) }
                running = reply.1
                if !reply.2.isEmpty { error = reply.2 }
                if !running {
                    // The helper returns at most 100 events. Drain its final batch before stopping.
                    if events.count == 100 { continue }
                    return
                }
            } catch {
                self.error = reply.2.isEmpty ? "Setup returned an invalid status." : reply.2
                await cancel(); return
            }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        }
    }

    func answer(_ value: Any, secret: Data? = nil) async {
        guard !busy, running, let id = timeline.prompt?.id,
              let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else { return }
        busy = true
        let ok: Bool = await withCheckedContinuation { continuation in
            guard let service = service(onError: { _ in continuation.resume(returning: false) }) else { continuation.resume(returning: false); return }
            service.answer(prompt: id, value: data, secret: secret) { continuation.resume(returning: $0) }
        }
        busy = false
        if ok { timeline.answered(id); error = nil }
        else { error = "The answer was not accepted. Check the setup connection." }
    }

    /// Whether this Mac can answer a Tailscale key prompt by itself, from the credential in its keychain.
    var holdsNetworkCredential: Bool { NetworkCredentialStore.isHeld }

    /// Answers the executor's one Tailscale question with a key this Mac mints: single-use, for this machine, and
    /// worthless in fifteen minutes. The owner presses once and types nothing; nothing is minted until they do.
    func answerNetworkKey() async {
        guard !busy, running, let credential = NetworkCredentialStore.read() else { return }
        do {
            let key = try await NetworkClient().key(for: configuration.name, with: credential)
            await answer("sent", secret: Data(key.utf8))
        } catch let failure {
            self.error = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
        }
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            guard let service = service(onError: { _ in continuation.resume() }) else { continuation.resume(); return }
            service.cancel { continuation.resume() }
        }
    }
}

/// The mark of a provider setup that goes on while its form does not show (the local installer, or the preparation by
/// a joined server): a spinner while it runs, an orange mark while it waits for the owner. The words are in the hover
/// text.
struct SetupMark: View {
    let setup: ProviderSetup
    let subject: String
    let place: String

    /// The state in words, or nil when no setup runs.
    static func words(_ setup: ProviderSetup, subject: String) -> String? {
        guard setup.running else { return nil }
        return setup.waits ? "\(subject) waits for your answer" : "\(subject) runs"
    }

    var body: some View {
        if let words = Self.words(setup, subject: subject) {
            Group {
                if setup.waits {
                    Image(systemName: "exclamationmark.circle").font(IconMetrics.symbol(12)).foregroundStyle(.orange)
                } else { ProgressView().controlSize(.mini) }
            }.help("\(words). \(place)").accessibilityLabel(words)
        }
    }
}

/// **The one thing a setup stops to ask**: a server identity to confirm, a key, the provider's own sign-in page, a
/// command to paste or a choice: the session's own open prompt. It stands with nothing else around it on the provider
/// and account card of one agent (`ProviderView`), where the steps of a setup are not his business and the question is.
struct SetupPromptView: View {
    @Bindable var session: ServerSetupSession
    @Binding var secret: String

    var body: some View {
        if let shown = session.timeline.prompt ?? session.timeline.signIn { ask(shown) }
    }

    @ViewBuilder private func ask(_ prompt: SetupEvent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch prompt.kind {
            case "confirm_host_key":
                Text("Confirm server identity").fontWeight(.medium)
                Text("Compare this fingerprint with your provider's server details.").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                Text("\(prompt.data?.host ?? ""):\(prompt.data?.port ?? 22)").textSelection(.enabled)
                ForEach(prompt.data?.fingerprints ?? [], id: \.sha256) { fingerprint in
                    Text("\(fingerprint.algorithm)  \(fingerprint.sha256)").font(FormMetrics.code).textSelection(.enabled)
                }
                HStack {
                    Button("Cancel") { Task { await session.answer(false) } }
                    Button("Trust this server") { Task { await session.answer(true) } }
                }.buttonStyle(FleetOutlineButtonStyle())
            case "secret":
                // A fleet whose private network is connected never types a key: this Mac makes one for this
                // machine, on one press.
                if prompt.data?.label == "tailscale_auth_key", session.holdsNetworkCredential {
                    Text("Put this server on your private network").fontWeight(.medium)
                    Text("A key for this server alone, used once and worthless in fifteen minutes.")
                        .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                    Button("Put it on the network") { Task { await session.answerNetworkKey() } }
                        .buttonStyle(FleetOutlineButtonStyle()).disabled(session.busy)
                        .accessibilityIdentifier("setup-network-key")
                } else {
                    let hint = prompt.data?.label == "tailscale_auth_key" ? "Tailscale auth key" : "Provider password"
                    SecureField(text: $secret, prompt: Text(verbatim: "")) { Text(hint) }
                        .fieldPlaceholder(hint, shows: secret.isEmpty)
                        .fleetField().accessibilityIdentifier("setup-secret")
                    Button("Continue") {
                        let value = Data(secret.utf8); secret = ""
                        Task { await session.answer("sent", secret: value) }
                    }.buttonStyle(FleetOutlineButtonStyle()).disabled(secret.isEmpty || secret.utf8.count > 2048)
                }
            case "open_url":
                if let code = prompt.data?.code { Text(code).font(FormMetrics.oneTimeCode).textSelection(.enabled) }
                if let url = prompt.loginURL {
                    Button("Sign in", systemImage: "arrow.up.right") {
                        if NSWorkspace.shared.open(url) { Task { await session.answer("opened") } }
                    }.buttonStyle(FleetOutlineButtonStyle())
                    Text(url.host ?? "").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                } else { Text("The installer returned an unsupported sign-in link.").foregroundStyle(.orange) }
            case "terminal":
                if let command = prompt.terminalCommand {
                    Text("Sign in to Claude Code").fontWeight(.medium)
                    Text("Paste the command into Terminal to sign in. Setup continues automatically.")
                        .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
                    // Copying only starts the wait; only the server's status ends it.
                    Button("Copy command", systemImage: "square.on.square") { copyMessage(command); Task { await session.answer("copied") } }
                        .buttonStyle(FleetOutlineButtonStyle()).accessibilityIdentifier("setup-copy-command")
                    DisclosureGroup("Command") {
                        Text(command).font(FormMetrics.code).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }.font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                } else { Text("The installer returned an unsupported command.").foregroundStyle(.orange) }
            case "choice":
                Text(prompt.data?.question ?? "Choose an option")
                ForEach(prompt.data?.options ?? [], id: \.value) { option in
                    Button(option.label) { Task { await session.answer(option.value) } }.buttonStyle(FleetOutlineButtonStyle())
                }
            default: Text("This setup prompt is not supported.").foregroundStyle(.orange)
            }
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.inner)).disabled(session.busy)
    }
}
