import Foundation

/// **A file that the app keeps, read whole, and only when it is a regular file of at most a given size.**
///
/// The app keeps small files that it reads by their names: its last reading of the hub for the window's first frame,
/// a request that waits to be sent, the records of its installs, this Mac's key for its hub. They were read with the
/// system's own reader (`Data(contentsOf:)`), some after a look at the file's size by its name. Three things were
/// wrong with that, in a place where a program of this Mac's own user can put any kind of file:
///
/// - **The file's kind was not asked.** What the system's reader does with a named pipe is the system's to decide:
///   macOS 27 refuses one at once (measured on 16 November 2026), and a reader that waits for the pipe's writer
///   holds its thread for ever. Several of these reads run on the app's main thread, and two at its start.
/// - **The size was asked of the name, or after the read, or not at all.** A link passes a look at its own few
///   bytes, and a file is whole in memory before a check of `data.count` refuses it.
/// - **Two looks by name are two files**, when the file is changed between them.
///
/// Here the file is opened once, with no wait, and then **the opened file itself** is asked what it is and how large
/// it is. Only a regular file within the caller's limit is read, and at most one byte more than the limit, so a file
/// that grows under the read is never taken whole into memory.
///
/// **This reader writes, moves and removes nothing.** What a caller then does at the file's name (a save of its own
/// file there, a removal) is that caller's rule, and this reader changes none of them.
///
/// **A link is followed, as the system's reader followed it**, and the check is of the file that the link leads to:
/// a link to a pipe, a device, a folder or a file that is too large is refused like the thing itself. So a regular
/// file within the limit is read behind a link as it was before. `followsLinks: false` refuses a link in the file's
/// own place (the records of `KeptRecords`, where a link is no record); a folder above the file can still be a link.
///
/// Not every file of the apps is read here: `KeptRecords` and the callers of `read` and `bytes` are.
public enum KeptFile {
    /// What a read gave.
    public enum Read: Equatable, Sendable {
        /// No file of that name (and a link that leads to none, when links are followed).
        case missing
        /// The file's bytes, whole.
        case bytes(Data)
        /// Something is there, and it is not read.
        case refused(Refusal)
    }

    /// Why a file that is there is not read.
    public enum Refusal: Equatable, Sendable {
        /// A named pipe, a socket, a device or a folder; and a link, when the caller does not follow links.
        case notAFile
        /// Larger than the caller's limit, by its own size or by what a read of it gave.
        case tooLarge
        /// It could not be opened or read: the system's own number for the cause (`EACCES`, `EIO`).
        case unreadable(errno: Int32)
    }

    /// The largest reading of the hub that the app reads for a window's first frame (`state-<hub>.json` and the
    /// readings beside it). The reading of a fleet with more than 800 finished tasks was 5 MB (measured on 16
    /// November 2026): this is 50 times that.
    public static let largestReading = 256 * 1024 * 1024
    /// The largest small record of the app that is one JSON file (the vault's removals, the key swap's state). The
    /// larger of the two was 2 KB on the same day.
    public static let largestRecord = 16 * 1024 * 1024

    /// Reads `file` whole when it is a regular file of at most `limit` bytes. It never waits for a writer, and it
    /// changes nothing on the disk.
    public static func read(_ file: URL, atMost limit: Int, followsLinks: Bool = true) -> Read {
        let limit = min(limit, Int.max - 1)
        let flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC | (followsLinks ? 0 : O_NOFOLLOW)
        // The cause is read in the same step as the open: only the call before it gives `errno` its meaning.
        var cause: Int32 = 0
        let descriptor = file.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { cause = ENOENT; return -1 }
            let descriptor = Darwin.open(path, flags)
            if descriptor < 0 { cause = errno }
            return descriptor
        }
        guard descriptor >= 0 else {
            switch cause {
            case ENOENT, ENOTDIR: return .missing
            // A link that is not followed (and a ring of links), and a socket, which no `open` takes.
            case ELOOP, EOPNOTSUPP: return .refused(.notAFile)
            default: return .refused(.unreadable(errno: cause))
            }
        }
        defer { Darwin.close(descriptor) }
        var facts = stat()
        guard Darwin.fstat(descriptor, &facts) == 0 else { return .refused(.unreadable(errno: errno)) }
        guard facts.st_mode & S_IFMT == S_IFREG else { return .refused(.notAFile) }
        guard limit >= 0, facts.st_size <= off_t(limit) else { return .refused(.tooLarge) }
        var data = Data()
        data.reserveCapacity(Int(facts.st_size))
        var piece = [UInt8](repeating: 0, count: min(limit + 1, 1024 * 1024))
        while data.count <= limit {
            let wanted = min(piece.count, limit + 1 - data.count)
            var failure: Int32 = 0
            let got = piece.withUnsafeMutableBytes { buffer -> Int in
                let got = Darwin.read(descriptor, buffer.baseAddress, wanted)
                if got < 0 { failure = errno }
                return got
            }
            if got < 0 {
                if failure == EINTR { continue }
                return .refused(.unreadable(errno: failure))
            }
            if got == 0 { return .bytes(data) }
            data.append(contentsOf: piece[..<got])
        }
        return .refused(.tooLarge)
    }

    /// The file's bytes, or nil for no file and for a file that is not read.
    public static func bytes(of file: URL, atMost limit: Int, followsLinks: Bool = true) -> Data? {
        if case .bytes(let data) = read(file, atMost: limit, followsLinks: followsLinks) { return data }
        return nil
    }

    /// **The system's own kind of error for a file that is not read**, for a caller that threw the system reader's
    /// error before and whose error a person can read: the same kind and so the same words for a file that this user
    /// may not read and for a folder (compared with that reader's errors on macOS 27.0.1). A named pipe gets the
    /// folder's kind, "could not be opened"; there that reader gave the kind of a file with no right to read.
    public static func systemError(_ refusal: Refusal, file: URL) -> CocoaError {
        var facts: [String: Any] = [NSFilePathErrorKey: file.path]
        let kind: CocoaError.Code
        switch refusal {
        case .notAFile: kind = .fileReadUnknown
        case .tooLarge: kind = .fileReadTooLarge
        case .unreadable(let cause):
            facts[NSUnderlyingErrorKey] = NSError(domain: NSPOSIXErrorDomain, code: Int(cause))
            kind = cause == EACCES || cause == EPERM ? .fileReadNoPermission : .fileReadUnknown
        }
        return CocoaError(kind, userInfo: facts)
    }
}
