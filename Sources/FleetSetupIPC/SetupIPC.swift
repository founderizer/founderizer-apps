import Foundation

public enum SetupServiceID {
    public static let name = "com.founderizer.setup"
}

/// The app sends typed configuration only. No method accepts a command or executable path.
@objc public protocol FleetSetupServiceProtocol {
    func availability(reply: @escaping (Bool, String) -> Void)
    /// The checked `onboard.py version` line, or empty data.
    func executorVersion(reply: @escaping (Data) -> Void)
    func start(configuration: Data, reply: @escaping (Bool, String) -> Void)
    func readEvents(after: Int, reply: @escaping (Data, Bool, String) -> Void)
    func answer(prompt: String, value: Data, secret: Data?, reply: @escaping (Bool) -> Void)
    func cancel(reply: @escaping () -> Void)
    func openScreenSharing(configuration: Data, reply: @escaping (Int, String) -> Void)
    func closeScreenSharing(configuration: Data, reply: @escaping () -> Void)
}
