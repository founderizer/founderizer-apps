import Foundation
import ImageIO

extension FleetTask {
    public func supportsDesktopPreview(in state: HubState) -> Bool {
        guard !isTerminal, state.ui_features?.contains("live_desktop") == true,
              state.holds?.contains(where: { $0.task == id && $0.state != "released" }) != true else { return false }
        if needs == "screen" { return true }
        return needs == "browser" && state.ui_features?.contains("browser_desktop") == true
    }
}

public struct DesktopContext: Hashable, Sendable {
    public let hub: URL
    public let database: String
    public let task: Int
    public let attempt: Int
    public init(hub: URL, database: String, task: Int, attempt: Int) {
        self.hub = hub; self.database = database; self.task = task; self.attempt = attempt
    }
    public func url() throws -> URL {
        guard task > 0, attempt > 0,
              var parts = URLComponents(url: hub.appendingPathComponent("ui/tasks/\(task)/desktop"), resolvingAgainstBaseURL: false)
        else { throw HubError.invalidAddress }
        parts.queryItems = [URLQueryItem(name: "db", value: database), URLQueryItem(name: "attempt", value: String(attempt))]
        guard let url = parts.url else { throw HubError.invalidAddress }
        return url
    }
}

public struct DesktopFrame: Decodable, Sendable {
    public let db: String
    public let task: Int
    public let attempt: Int
    public let status: String
    public let captured_at: Double?
    public let image: String?

    public func validatedImage(in context: DesktopContext, now: Double = Date().timeIntervalSince1970) throws -> Data? {
        guard db == context.database, task == context.task, attempt == context.attempt else { throw ArtifactError.identity }
        guard ["waiting", "live", "permission_required", "locked", "unavailable"].contains(status) else { throw HubError.invalidResponse }
        guard status == "live" else {
            guard image == nil, captured_at == nil else { throw HubError.invalidResponse }
            return nil
        }
        guard let captured_at, captured_at.isFinite, now - captured_at <= 7, captured_at <= now + 3 else { throw ArtifactError.stale }
        guard let image, image.utf8.count <= 1_398_104, let data = Data(base64Encoded: image), data.count <= 1_048_576,
              data.starts(with: [0xff, 0xd8, 0xff]),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 2560, height <= 2560 else { throw ArtifactError.image }
        return data
    }
}
