import AppKit
import FleetCore
import FleetSetupIPC
import Observation

@MainActor @Observable
final class ScreenSharingSession {
    static let shared = ScreenSharingSession()
    private(set) var busy: Set<ScreenSharingConnection> = []
    private(set) var opened: Set<ScreenSharingConnection> = []
    private(set) var errors: [ScreenSharingConnection: String] = [:]
    private var connection: NSXPCConnection?
    private var connectionID: UUID?

    private func service(onError: @escaping @Sendable (Error) -> Void) -> FleetSetupServiceProtocol? {
        if connection == nil {
            let id = UUID()
            let connection = NSXPCConnection(serviceName: SetupServiceID.name)
            connection.remoteObjectInterface = NSXPCInterface(with: FleetSetupServiceProtocol.self)
            connection.interruptionHandler = { [weak self] in Task { @MainActor in self?.disconnected(id) } }
            connection.invalidationHandler = { [weak self] in Task { @MainActor in self?.disconnected(id) } }
            connection.resume(); self.connection = connection; connectionID = id
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? FleetSetupServiceProtocol
    }

    private func disconnected(_ id: UUID) {
        guard id == connectionID else { return }
        for request in opened { errors[request] = String(l10n: "The Screen Sharing connection closed. Open it again to reconnect.") }
        opened.removeAll(); connection = nil; connectionID = nil
    }

    func open(_ request: ScreenSharingConnection) async {
        guard request.isValid, !busy.contains(request), let data = try? JSONEncoder().encode(request) else { return }
        busy.insert(request); errors[request] = nil
        defer { busy.remove(request) }
        let result: (Int, String) = await withCheckedContinuation { continuation in
            let reply = ScreenSharingReply(continuation)
            guard let service = service(onError: { _ in reply.finish((0, String(l10n: "The local connection helper is unavailable."))) }) else {
                reply.finish((0, String(l10n: "The local connection helper is unavailable."))); return
            }
            service.openScreenSharing(configuration: data) { port, detail in reply.finish((port, detail)) }
        }
        guard (1024...65535).contains(result.0) else {
            opened.remove(request)
            errors[request] = result.1.isEmpty ? String(l10n: "Screen Sharing could not connect.") : result.1
            return
        }
        opened.insert(request)
        if !NSWorkspace.shared.open(URL(string: "vnc://127.0.0.1:\(result.0)")!) {
            if await closeConnection(data) { opened.remove(request) }
            errors[request] = String(l10n: "The Screen Sharing app could not open.")
        }
    }

    func close(_ request: ScreenSharingConnection) async {
        guard !busy.contains(request), let data = try? JSONEncoder().encode(request) else { return }
        busy.insert(request)
        defer { busy.remove(request) }
        if await closeConnection(data) { opened.remove(request); errors[request] = nil }
        else { errors[request] = String(l10n: "The connection helper did not confirm disconnection. Quit Founderizer to close its connections.") }
    }

    private func closeConnection(_ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            let reply = ScreenSharingReply(continuation)
            guard let service = service(onError: { _ in reply.finish(false) }) else { reply.finish(false); return }
            service.closeScreenSharing(configuration: data) { reply.finish(true) }
        }
    }

    func shutdown() { connectionID = nil; connection?.invalidate(); connection = nil }
}

// An XPC interruption can race its reply. Resume each request once.
private final class ScreenSharingReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    func finish(_ value: Value) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(returning: value)
    }
}
