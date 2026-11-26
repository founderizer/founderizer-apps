import CryptoKit
import Foundation

/// One copy of the owner's fleet, on the owner's own machine (owner API 1.5).
///
/// This is the whole of the backup warning's answer. The hub writes, keeps and schedules nothing — the owner's own
/// rule — so the only copy that exists is the one this Mac takes and keeps, and the hub counts a copy as made only
/// once this Mac has saved it and said so. Until 19 October 2026 nothing in the app pressed either route, so the
/// System status screen said "The owner has no confirmed backup of the hub database" and offered nothing.
///
/// The bytes never pass through memory whole: a copy has no limit of size (the owner, 22 November 2026: "why is there a
/// backup limit? it shouldn't?"), so it is written into a file of this app's own as it arrives, its SHA-256 is read from
/// that file in blocks, and only a file whose digest is the one the hub served is offered to the owner to keep. The
/// bound is this Mac's free space, which is read against the answer's `Content-Length` before the first byte is written
/// (`room`).
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

    /// What a copy leaves free on this Mac's disk beside itself, as the hub keeps `COPY_RESERVE` beside its own: a copy
    /// that took the system disk to 0 bytes would stop macOS's own writes (the second reader's N2, 22 November 2026).
    public static let reserve: Int64 = 256 << 20

    /// Whether a copy of `length` bytes (the answer's `Content-Length`, -1 when it gave none) goes onto a disk with
    /// `free` bytes free (nil when the system does not say) with `reserve` beside it: nil when it does, else the
    /// refusal, whose need is the copy and that reserve, as the hub's words say its own. An answer with no length is
    /// refused, because an answer with no end could fill the disk.
    public static func room(length: Int64, free: Int64?) -> FleetCopyError? {
        guard length >= 0 else { return .noLength }
        // No sum of the length: a length near Int64.max would stop the app (the second reader's R2-2).
        guard let free, free - reserve < length else { return nil }
        let need = length.addingReportingOverflow(reserve)
        return .noRoom(need: need.overflow ? .max : need.partialValue, free: free)
    }

    /// The start of the name of each folder that `takeCopy` makes for a copy in the temporary folder:
    /// `founderizer-copy-<pid>-<UUID>`, with the number of the process that takes the copy.
    static let arriving = "founderizer-copy-"

    /// The name of a new folder for a copy of this process.
    static func arrivingName() -> String { arriving + "\(getpid())-" + UUID().uuidString }

    /// **The folders of copies that an earlier process of this app left in the temporary folder** (the second reader's
    /// N3, 22 November 2026): `takeCopy` removes its folder at the copy's end, but a quit, an update's restart, a crash
    /// or a power loss during a download leaves its folder with a part of up to the copy's size, which nothing else
    /// removes and which the next room check counts as used. The app removes them at its start: only folders of that
    /// exact name (no link, no file), made before `start`, the start of this process. Each process of an account shares
    /// that temporary folder, so a folder `founderizer-copy-<pid>-<UUID>` goes only when its process runs no more
    /// (`kill(pid, 0)` gives ESRCH): a second app process (a test build, `open -n`, a test of the app) never removes a
    /// copy that the first still takes, holds behind the save panel or moves (the second reader's R2-1). A number that
    /// came to another process keeps its folder until that one ends. A name with no number, `founderizer-copy-<UUID>`,
    /// is of an app from before the number, which can run beside this one and hold its copy there through the save
    /// panel: it stays, and macOS's own cleanup of the temporary folder takes it in time (the second reader's R3-1).
    /// The names removed.
    @discardableResult
    public static func leftoversGone(before start: Date,
                                     in folder: URL = URL(fileURLWithPath: NSTemporaryDirectory())) -> [String] {
        let manager = FileManager.default
        var gone: [String] = []
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] {
            guard name.hasPrefix(arriving) else { continue }
            let rest = name.dropFirst(arriving.count)
            guard let dash = rest.firstIndex(of: "-"), let owner = pid_t(rest[..<dash]), owner > 0,
                  UUID(uuidString: String(rest[rest.index(after: dash)...])) != nil else { continue }
            let place = folder.appendingPathComponent(name)
            guard let values = try? place.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]),
                  values.isDirectory == true, values.isSymbolicLink != true, let made = values.creationDate, made < start
            else { continue }
            if !(kill(owner, 0) == -1 && errno == ESRCH) { continue }     // its process runs
            if (try? manager.removeItem(at: place)) != nil { gone.append(name) }
        }
        return gone.sorted()
    }

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

public enum FleetCopyError: LocalizedError, Sendable, Equatable {
    case refused(Int, String), noRoom(need: Int64, free: Int64), noLength, checksum, cannotKeep(String)
    public var errorDescription: String? {
        switch self {
        case .refused(403, _): String(l10n: "This hub does not serve copies. Its team file turned them off.")
        case .refused(409, _): String(l10n: "The hub changed while the copy was being taken. Refresh and take it again.")
        case .refused(let status, let message):
            message.isEmpty ? String(l10n: "The hub could not give the copy (HTTP \(status)).") : message
        case .noRoom(let need, let free):
            String(l10n: "This Mac has no room for the copy. It needs \(FleetHealth.storageWords(need, rounding: .up)), and \(FleetHealth.storageWords(free, rounding: .down)) is free.")
        case .noLength: HubError.invalidResponse.errorDescription
        case .checksum: String(l10n: "The copy that arrived is not the copy the hub sent. Nothing was saved; try again.")
        case .cannotKeep(let reason): String(l10n: "The copy could not be saved: \(reason)")
        }
    }
}

extension HubClient {
    /// `GET /ui/backup`: one copy of this fleet, into a file of this app's own. No copy stays on the hub.
    ///
    /// The digest is read back from the file that landed and checked against the hub's own
    /// `X-Fleet-Backup-SHA256`, so a copy that arrived damaged is never offered to the owner and never confirmed.
    /// The copy is written into the file as it arrives (`CopyDownload`), after its `Content-Length` was read against the
    /// free space of this Mac's disk (`FleetCopy.room`). No clock ends a transfer that moves: the hub makes the copy
    /// before its first byte, so a byte may take 600 seconds, and the whole has no limit of time. The copy's folder,
    /// `founderizer-copy-<pid>-<UUID>` (`FleetCopy.leftoversGone`), is made in `temporary`: this Mac's temporary folder,
    /// or a test's own.
    public func takeCopy(hub: URL, database: String,
                         in temporary: URL = URL(fileURLWithPath: NSTemporaryDirectory())) async throws -> FleetCopy {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/backup"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/zip", forHTTPHeaderField: "Accept")
        let folder = temporary.appendingPathComponent(FleetCopy.arrivingName())
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            // Mode 600, new, and no link: the copy holds every record, and the copy that he keeps holds the fleet's
            // access key too. Its mode goes with it into the `with-key-` copy and his folder, where other accounts of
            // this Mac can read a file of mode 644 (the second reader's M1, 22 November 2026; URLSession's own
            // download file was 600).
            let arriving = folder.appendingPathComponent("copy.part")
            let made = open(arriving.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard made >= 0 else { throw FleetCopyError.cannotKeep(String(cString: strerror(errno))) }
            close(made)
            let http = try await CopyDownload(file: arriving).run(request)
            guard http.response.statusCode == 200 else {
                throw FleetCopyError.refused(http.response.statusCode,
                                             HubRefusal.read(status: http.response.statusCode, body: http.words).said ?? "")
            }
            let name = FleetCopy.name(fromDisposition: http.response.value(forHTTPHeaderField: "Content-Disposition"))
            let file = folder.appendingPathComponent(name)
            try FileManager.default.moveItem(at: arriving, to: file)
            let bytes = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes > 0 else { throw FleetCopyError.checksum }
            let digest = try FleetCopy.digest(of: file)
            guard http.response.value(forHTTPHeaderField: "X-Fleet-DB") == database,
                  http.response.value(forHTTPHeaderField: "X-Fleet-Backup-SHA256") == digest else {
                throw FleetCopyError.checksum
            }
            return FleetCopy(file: file, suggestedName: name, sha256: digest, bytes: bytes)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// `POST /ui/backups/confirm`: this Mac saved that copy and checked it. Only a copy that the hub served is taken, so
    /// a copy that was never saved never clears the warning. `keyed` says whether the copy that was kept carries the
    /// fleet's access key (`OwnerAccess.withKey`): only such a copy answers the hub's warnings (UI-API.md 1.346), and
    /// `maker` who saved it, this Mac app.
    @discardableResult
    public func confirmCopy(hub: URL, database: String, client: String, requestID: UUID = UUID(),
                            sha256: String, bytes: Int64, keyed: Bool, maker: String = "mac") async throws -> FleetHealth.Backup {
        guard FleetHealth.Backup.isDigest(sha256), bytes > 0 else { throw HubError.invalidResponse }
        let data = try await ownerCommand("ui/backups/confirm", hub: hub, database: database, client: client,
                                          requestID: requestID,
                                          fields: ["sha256": sha256, "bytes": Int(bytes), "keyed": keyed, "maker": maker])
        let receipt = try JSONDecoder().decode(CopyReceipt.self, from: data)
        guard receipt.ok, receipt.backup.sha256 == sha256, receipt.backup.bytes == bytes else {
            throw HubError.invalidResponse
        }
        return receipt.backup
    }

    private struct CopyReceipt: Decodable { let ok: Bool; let backup: FleetHealth.Backup }
}

/// **One copy of the fleet, written into a file as it arrives** (`HubClient.takeCopy`): a data task whose answer of 200
/// goes into `file` in the parts that the network gives, and whose answer of any other status is words, at most 8 KiB.
/// Before the first byte of a copy it reads the answer's `Content-Length` against the free space of the file's disk
/// (`FleetCopy.room`) and ends the task when the copy cannot fit, so an answer with no end cannot fill this Mac.
final class CopyDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let file: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private var response: HTTPURLResponse?
    private var words = Data()
    private var failure: Error?
    private var finished: CheckedContinuation<(response: HTTPURLResponse, words: Data), Error>?

    init(file: URL) { self.file = file }

    /// The answer, with the words of a refusal; the copy is in `file` when it is a 200. The request goes with this
    /// Mac's key for its hub (`OwnerMacKey.authorized`), signed at the send itself: a data task with a delegate of its
    /// own cannot go through `hubData` (OwnerMacKeyTests names this file).
    func run(_ request: URLRequest) async throws -> (response: HTTPURLResponse, words: Data) {
        let configuration = URLSessionConfiguration.ephemeral
        // A wait for the next byte that covers the hub's making of the copy; no limit for the whole (the system's
        // own default of seven days), because no clock may end a transfer that moves.
        configuration.timeoutIntervalForRequest = 600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            finished = continuation
            lock.unlock()
            session.dataTask(with: OwnerMacKey.authorized(request)).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let http = response as? HTTPURLResponse else {
            failure = HubError.invalidResponse
            return completionHandler(.cancel)
        }
        self.response = http
        guard http.statusCode == 200 else { return completionHandler(.allow) }
        let free = (try? file.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        if let refused = FleetCopy.room(length: http.expectedContentLength, free: free) {
            failure = refused
            return completionHandler(.cancel)
        }
        do {
            handle = try FileHandle(forWritingTo: file)
        } catch {
            failure = FleetCopyError.cannotKeep(error.localizedDescription)
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil else { return }
        if let handle {
            do { try handle.write(contentsOf: data) } catch {
                failure = FleetCopyError.cannotKeep(error.localizedDescription)
                dataTask.cancel()
            }
        } else if words.count + data.count <= 8192 {
            words.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        try? handle?.close()
        handle = nil
        let continuation = finished
        finished = nil
        let result: Result<(response: HTTPURLResponse, words: Data), Error>
        if let failure {
            result = .failure(failure)
        } else if let error {
            result = .failure(error)
        } else if let response {
            result = .success((response, words))
        } else {
            result = .failure(HubError.invalidResponse)
        }
        lock.unlock()
        continuation?.resume(with: result)
    }
}
