import FleetCore
import Foundation

/// **An import of secrets from another password manager** (Bitwarden or 1Password), on the owner's Mac. The owner
/// exports his items into a file with that manager's own export and picks the file; each item that he keeps checked
/// becomes one secret of the fleet's vault, saved as Add secret saves one (the owner's yes of 11 November 2026 to its
/// pages, `SecretImportView`). This type only reads the file: in this process, once, with no program of a vendor, no
/// network and no file of its own, and it gives the values to the rows and to nothing else. No value reaches a log, a
/// command argument, an environment variable or a temporary file. No vendor library, account or token is involved:
/// the formats are read from the vendors' own published documentation.
///
/// What it reads: a Bitwarden Password Manager `.json` export, plain or locked with a password of the file's own
/// (PBKDF2 or Argon2id, `ExportCrypto`), and a Bitwarden Secrets Manager `.json` export; a 1Password `.1pux` export
/// and a 1Password `.csv` export. A file that only the Bitwarden account's own key opens is named as such, and not
/// read. A vendor's command line program is not used: Bitwarden's `bw` takes its session key in an argument or in the
/// environment, and 1Password's API terms read against a bulk export with its `op`.
public struct SecretImport: Sendable, Equatable {
    public enum Vendor: String, Sendable, CaseIterable { case bitwarden, onePassword }

    /// Why a file gives no rows, in the screen's words.
    public enum Failure: Error, Equatable, LocalizedError {
        case notAnExport(Vendor), password(wrong: Bool), lockedToAccount, tooLarge, damaged, unreadable

        public var errorDescription: String? {
            switch self {
            case .notAnExport(.bitwarden): "This is not a Bitwarden export. Choose the .json file that Bitwarden made."
            case .notAnExport(.onePassword): "This is not a 1Password export. Choose the .1pux or .csv file that 1Password made."
            case .password(wrong: false): "This file has a password. Enter the password that you set at the export."
            case .password(wrong: true): "This password does not open the file."
            case .lockedToAccount: "Only your Bitwarden account can open this file. Export again as .json, or as .json (Encrypted) with a file password."
            case .tooLarge: "This file is too large to import."
            case .damaged: "This file is damaged. Export again."
            case .unreadable: "Founderizer could not read this file."
            }
        }
    }

    /// One item that can become a secret. `problem` is why the vaults cannot read it as it is, in Add secret's words:
    /// such a row is shown and cannot be chosen.
    public struct Row: Identifiable, Sendable, Equatable {
        public let id: Int
        public let secret: LoginSecret
        public var problem: String? { secret.problem }
        public init(id: Int, secret: LoginSecret) { self.id = id; self.secret = secret }
    }

    /// The kinds of items that are not imported, and how many of each.
    public enum Skipped: String, Sendable, CaseIterable {
        case note, card, identity, sshKey, document, archived, noPassword, noAddress, unreadable, other
    }

    public let vendor: Vendor
    public let rows: [Row]
    public let skipped: [Skipped: Int]

    /// The largest file that the import opens. An export with attachments (a `.1pux` can have them) is read in parts.
    public static let fileLimit: UInt64 = 1 << 31

    /// Reads one export file. `password` is the file's own password, for a Bitwarden file that has one. It blocks while
    /// it reads, and an Argon2id file takes a moment more: call it away from the main thread.
    public static func read(_ url: URL, vendor: Vendor, password: String? = nil) throws -> SecretImport {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.unreadable }
        defer { try? handle.close() }
        let file = OpenFile(handle: handle)
        guard file.size <= fileLimit else { throw Failure.tooLarge }
        func whole() throws -> Data {
            guard file.size <= UInt64(ExportReader.dataLimit) else { throw Failure.tooLarge }
            return try file.read(at: 0, count: Int(file.size))
        }
        do {
            let reading: ExportReading
            switch vendor {
            case .bitwarden:
                reading = try ExportReader.bitwarden(try whole(), password: password)
            case .onePassword:
                // A `.1pux` is a zip file, a `.csv` is text: the first bytes say which, not the file's name.
                let zip = try file.read(at: 0, count: Int(min(file.size, 4))) == Data([0x50, 0x4B, 0x03, 0x04])
                reading = zip ? try ExportReader.onePassword(file) : try ExportReader.onePasswordCSV(try whole())
            }
            return Self(vendor: vendor, reading: reading)
        } catch let failure as ExportReader.Failure {
            switch failure {
            case .notAnExport: throw Failure.notAnExport(vendor)
            case .password(let wrong): throw Failure.password(wrong: wrong)
            case .lockedToAccount: throw Failure.lockedToAccount
            case .tooLarge: throw Failure.tooLarge
            case .damaged: throw Failure.damaged
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreadable
        }
    }

    init(vendor: Vendor, reading: ExportReading) {
        self.vendor = vendor
        var rows: [Row] = [], skipped: [Skipped: Int] = [:]
        for found in reading.found {
            guard let candidate = found.candidate else {
                let kind: Skipped = switch found.skipped {
                case .note: .note
                case .card: .card
                case .identity: .identity
                case .sshKey: .sshKey
                case .document: .document
                case .archived: .archived
                case .noValue: .noPassword
                case .noAddress: .noAddress
                case .unreadable: .unreadable
                case .otherKind, nil: .other
                }
                skipped[kind, default: 0] += 1
                continue
            }
            var secret = LoginSecret()
            secret.kind = candidate.kind == .login ? .login : .apiKey
            secret.url = candidate.url
            secret.username = candidate.username
            secret.password = candidate.password
            secret.totp = candidate.totp
            secret.env = candidate.env
            rows.append(Row(id: rows.count, secret: secret))
        }
        self.rows = rows
        self.skipped = skipped
    }

    /// One line for the items that are not imported, or nil: "Not imported: 2 notes and 1 card."
    public var skippedLine: String? {
        let parts: [String] = Skipped.allCases.compactMap { kind in
            guard let count = skipped[kind], count > 0 else { return nil }
            let (one, many) = switch kind {
            case .note: ("note", "notes")
            case .card: ("card", "cards")
            case .identity: ("identity", "identities")
            case .sshKey: ("SSH key", "SSH keys")
            case .document: ("document", "documents")
            case .archived: ("archived item", "archived items")
            case .noPassword: ("item with no password", "items with no password")
            case .noAddress: ("login with no web address", "logins with no web address")
            case .unreadable: ("item that was not readable", "items that were not readable")
            case .other: ("item of another kind", "items of another kind")
            }
            return "\(count) \(count == 1 ? one : many)"
        }
        guard !parts.isEmpty else { return nil }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        return "Not imported: \(list)."
    }

    /// An open file, read in parts.
    private struct OpenFile: ExportBytes {
        let handle: FileHandle
        let size: UInt64

        init(handle: FileHandle) {
            self.handle = handle
            size = (try? handle.seekToEnd()) ?? 0
        }

        func read(at offset: UInt64, count: Int) throws -> Data {
            guard count > 0 else { return Data() }
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else { throw ZipEntry.Failure.damaged }
            return data
        }
    }
}
