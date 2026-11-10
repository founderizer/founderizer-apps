import CryptoKit
import Foundation
import ImageIO

public struct ArtifactContext: Equatable, Hashable, Sendable {
    public let hub: URL
    public let database: String
    public let taskID: Int

    public init(hub: URL, database: String, taskID: Int) {
        self.hub = hub
        self.database = database
        self.taskID = taskID
    }

    public func listURL() throws -> URL {
        guard taskID > 0, !database.isEmpty else { throw ArtifactError.identity }
        guard hub == (try HubClient.address(hub.absoluteString)) else { throw ArtifactError.identity }
        guard var parts = URLComponents(url: hub.appendingPathComponent("ui/tasks/\(taskID)/artifacts"), resolvingAgainstBaseURL: false) else { throw ArtifactError.identity }
        parts.queryItems = [URLQueryItem(name: "db", value: database)]
        guard let url = parts.url else { throw ArtifactError.identity }
        return url
    }

    public func fileURL(_ artifact: CheckedArtifact) throws -> URL {
        try artifact.validate()
        guard taskID > 0, !database.isEmpty else { throw ArtifactError.identity }
        guard hub == (try HubClient.address(hub.absoluteString)) else { throw ArtifactError.identity }
        guard var parts = URLComponents(url: hub.appendingPathComponent("ui/tasks/\(taskID)/artifact"), resolvingAgainstBaseURL: false) else { throw ArtifactError.identity }
        parts.queryItems = [URLQueryItem(name: "db", value: database),
                            URLQueryItem(name: "path", value: artifact.path),
                            URLQueryItem(name: "commit", value: artifact.commit)]
        guard let url = parts.url else { throw ArtifactError.identity }
        return url
    }
}

public struct CheckedArtifact: Decodable, Identifiable, Equatable, Sendable {
    public let path: String
    public let commit: String
    public let sha256: String
    public let bytes: Int
    public let mime: String
    public var id: String { path }
    public var isImage: Bool { mime == "image/png" || mime == "image/jpeg" }

    public func validate() throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\\%:?#"))
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                     "txt": "text/plain", "md": "text/plain", "json": "text/plain", "csv": "text/plain"]
        guard path.hasPrefix("outputs/"), path.utf8.count <= 1024,
              parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              path.rangeOfCharacter(from: forbidden) == nil,
              types[(path as NSString).pathExtension.lowercased()] == mime,
              Self.isHex(commit, count: 40), Self.isHex(sha256, count: 64),
              ["image/png", "image/jpeg", "text/plain"].contains(mime),
              bytes >= 0, bytes <= (isImage ? 8 * 1024 * 1024 : 256 * 1024)
        else { throw ArtifactError.metadata }
    }

    private static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
}

public struct ArtifactList: Decodable, Sendable {
    public let db: String
    public let task: Int
    public let artifacts: [CheckedArtifact]

    public static func decode(_ data: Data, context: ArtifactContext) throws -> ArtifactList {
        guard data.count <= 256 * 1024 else { throw ArtifactError.size }
        let list = try JSONDecoder().decode(Self.self, from: data)
        guard list.db == context.database, list.task == context.taskID else { throw ArtifactError.identity }
        guard Set(list.artifacts.map(\.path)).count == list.artifacts.count,
              Set(list.artifacts.map { $0.commit.lowercased() }).count <= 1 else { throw ArtifactError.metadata }
        try list.artifacts.forEach { try $0.validate() }
        return list
    }
}

public enum ArtifactPayload: Sendable {
    case text(String)
    case image(Data)
}

public enum ArtifactValidation {
    public static func response(_ response: HTTPURLResponse, artifact: CheckedArtifact, context: ArtifactContext) throws {
        try artifact.validate()
        guard response.url == (try context.fileURL(artifact)), response.statusCode == 200,
              response.value(forHTTPHeaderField: "X-Fleet-DB") == context.database,
              response.value(forHTTPHeaderField: "X-Fleet-Task") == String(context.taskID),
              response.value(forHTTPHeaderField: "X-Fleet-Commit")?.lowercased() == artifact.commit.lowercased()
        else { throw ArtifactError.identity }
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "")
            .split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard contentType.first == artifact.mime,
              contentType.dropFirst().allSatisfy({ $0 == "charset=utf-8" || $0 == "charset=\"utf-8\"" }),
              response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true
        else { throw ArtifactError.mime }
        guard response.expectedContentLength == artifact.bytes else { throw ArtifactError.size }
    }

    public static func payload(_ data: Data, artifact: CheckedArtifact) throws -> ArtifactPayload {
        try artifact.validate()
        guard data.count == artifact.bytes else { throw ArtifactError.size }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == artifact.sha256.lowercased() else { throw ArtifactError.checksum }
        if artifact.mime == "text/plain" {
            guard let text = String(data: data, encoding: .utf8) else { throw ArtifactError.utf8 }
            return .text(text)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              type == (artifact.mime == "image/png" ? "public.png" : "public.jpeg"),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 40_000_000
        else { throw ArtifactError.image }
        return .image(data)
    }
}

public enum ArtifactError: LocalizedError, Equatable, Sendable {
    case identity, metadata, size, mime, checksum, utf8, image, stale, refusedText
    public var errorDescription: String? {
        switch self {
        case .identity: "The output response belongs to a different hub, generation, task or revision. Reload checked outputs."
        case .metadata: "The hub returned an unsupported or invalid output reference."
        case .size: "The output size does not match its checked reference or exceeds the display limit."
        case .mime: "The output file type does not match its checked reference."
        case .checksum: "The output checksum does not match its checked reference. Reload checked outputs."
        case .utf8: "The output is not valid UTF-8 text."
        case .image: "The image cannot be displayed safely. Supported images are PNG or JPEG, up to 40 million pixels."
        case .stale: "The checked output list changed. Reload checked outputs."
        case .refusedText: "The hub blocked text that contains a registered login. Nothing was displayed or saved."
        }
    }
}
