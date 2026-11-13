import CryptoKit
import Foundation

/// One copy of the owner's fleet, on the owner's own machine (owner API 1.5).
///
/// This is the whole of the backup warning's answer. The hub writes, keeps and schedules nothing — the owner's own
/// rule — so the only copy that exists is the one this Mac takes and keeps, and the hub counts a copy as made only
/// once this Mac has saved it and said so. Until 19 October 2026 nothing in the app pressed either route, so the
/// System status screen said "The owner has no confirmed backup of the hub database" and offered nothing.
///
/// The bytes never pass through memory whole: a copy may be 256 MiB, so it is downloaded to a file of this app's
/// own, its SHA-256 is read from that file in blocks, and only a file whose digest is the one the hub served is
/// offered to the owner to keep.
public struct FleetCopy: Sendable {
    /// Where this Mac put it while the owner decides where to keep it. It is inside a folder this app made for it.
    public let file: URL
    /// The name the hub gave it: `founderizer-<fleet id>-<time>.zip`.
    public let suggestedName: String
    public let sha256: String
    public let bytes: Int64

    public init(file: URL, suggestedName: String, sha256: String, bytes: Int64) {
        self.file = file; self.suggestedName = suggestedName; self.sha256 = sha256; self.bytes = bytes
    }

    /// At most what the hub itself serves (`BACKUP_MAX`). A larger fleet is copied on the hub machine.
    public static let sizeLimit: Int64 = 256 * 1024 * 1024

    /// The SHA-256 of a file, read in blocks so that no copy is ever held in memory.
    public static func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty { hash.update(data: block) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The name out of `Content-Disposition`, with every path separator taken out, or a name of this Mac's own. A
    /// file name the hub chose is still a name from the network: it may not decide where this Mac writes.
    static func name(fromDisposition header: String?, at time: Date = Date()) -> String {
        let fallback = "founderizer-" + Self.stamp.string(from: time) + ".zip"
        guard let header, let range = header.range(of: "filename=") else { return fallback }
        let raw = header[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\" ;"))
        let safe = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:")).last ?? ""
        guard safe.hasSuffix(".zip"), safe.count <= 128, !safe.hasPrefix("."),
              safe.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return fallback }
        return safe
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}

public enum FleetCopyError: LocalizedError, Sendable {
    case refused(Int, String), tooLarge, checksum, cannotKeep(String)
    public var errorDescription: String? {
        switch self {
        case .refused(403, _): String(l10n: "This hub does not serve copies. Its team file turned them off.")
        case .refused(409, _): String(l10n: "The hub changed while the copy was being taken. Refresh and take it again.")
        case .refused(let status, let message):
            message.isEmpty ? String(l10n: "The hub could not give the copy (HTTP \(status)).") : message
        case .tooLarge: String(l10n: "This fleet is larger than 256 MiB. Take the copy on the hub server itself.")
        case .checksum: String(l10n: "The copy that arrived is not the copy the hub sent. Nothing was saved; try again.")
        case .cannotKeep(let reason): String(l10n: "The copy could not be saved: \(reason)")
        }
    }
}

extension HubClient {
    /// `GET /ui/backup`: one copy of this fleet, into a file of this app's own. Nothing is written on the hub.
    ///
    /// The digest is read back from the file that landed and checked against the hub's own
    /// `X-Fleet-Backup-SHA256`, so a copy that arrived damaged is never offered to the owner and never confirmed.
    public func takeCopy(hub: URL, database: String) async throws -> FleetCopy {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/backup"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/zip", forHTTPHeaderField: "Accept")
        // A copy takes as long as it takes: the client's own session is set for the short owner calls.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 900
        let transfer = URLSession(configuration: configuration)
        defer { transfer.finishTasksAndInvalidate() }
        let (temporary, response) = try await transfer.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw FleetCopyError.refused(http.statusCode, Self.refusal(at: temporary))
        }
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("founderizer-copy-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let name = FleetCopy.name(fromDisposition: http.value(forHTTPHeaderField: "Content-Disposition"))
            let file = folder.appendingPathComponent(name)
            try FileManager.default.moveItem(at: temporary, to: file)
            let bytes = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes > 0, bytes <= FleetCopy.sizeLimit else { throw FleetCopyError.tooLarge }
            let digest = try FleetCopy.digest(of: file)
            guard http.value(forHTTPHeaderField: "X-Fleet-DB") == database,
                  http.value(forHTTPHeaderField: "X-Fleet-Backup-SHA256") == digest else { throw FleetCopyError.checksum }
            return FleetCopy(file: file, suggestedName: name, sha256: digest, bytes: bytes)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// `POST /ui/backups/confirm`: this Mac saved that copy and checked it. Only the copy the hub served last is
    /// taken, so a copy that was never saved never clears the warning.
    @discardableResult
    public func confirmCopy(hub: URL, database: String, client: String, requestID: UUID = UUID(),
                            sha256: String, bytes: Int64) async throws -> FleetHealth.Backup {
        guard FleetHealth.Backup.isDigest(sha256), bytes > 0 else { throw HubError.invalidResponse }
        let data = try await ownerCommand("ui/backups/confirm", hub: hub, database: database, client: client,
                                          requestID: requestID,
                                          fields: ["sha256": sha256, "bytes": Int(bytes)])
        let receipt = try JSONDecoder().decode(CopyReceipt.self, from: data)
        guard receipt.ok, receipt.backup.sha256 == sha256, receipt.backup.bytes == bytes else {
            throw HubError.invalidResponse
        }
        return receipt.backup
    }

    private struct CopyReceipt: Decodable { let ok: Bool; let backup: FleetHealth.Backup }

    /// What the hub said when it refused, from the body it wrote to the download file.
    private static func refusal(at file: URL) -> String {
        guard let data = try? Data(contentsOf: file), data.count <= 8192,
              let body = try? JSONDecoder().decode(ErrorBody.self, from: data) else { return "" }
        return body.error
    }
}
