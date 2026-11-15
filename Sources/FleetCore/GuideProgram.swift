#if os(macOS)
import CryptoKit
import Foundation
import Security

/// **The provider's program that the guide's session runs, and the two checks that each start makes** (spec section
/// 3.2, lane S). The program is Claude Code, as Anthropic publishes it: the app does not change the file, and it never
/// updates, changes or deletes the owner's own program.
///
/// The app uses the owner's own program when that file is a version that passed the guide's tool-list test, by its
/// SHA-256. Else it gets a tested version into its own folder. Each file that the app starts has passed two checks at
/// that start: its SHA-256 is on the list, and its code signature is a Developer ID of the provider's team.
public enum GuideProgram {
    /// Anthropic's Apple Developer team (`codesign -dv` of the published file: "Developer ID Application: Anthropic
    /// PBC").
    public static let team = "Q6L2SF6YDW"

    /// One version that passed the guide's live tool-list test, with the SHA-256 of its file for each kind of Mac,
    /// from the provider's own `manifest.json` of that version.
    public struct Tested: Equatable, Sendable {
        public let number: String
        /// By the provider's name of the kind of Mac: `darwin-arm64`, `darwin-x64`.
        public let sha256: [String: String]
        public init(number: String, sha256: [String: String]) { self.number = number; self.sha256 = sha256 }
    }

    /// **The tested versions.** A version joins this list only when the live tool-list test passed on it
    /// (`GuideLiveTests`, behind `FOUNDERIZER_LIVE_GUIDE`): the tool list, the rule on long tool calls, the program's
    /// own socket and what it reads in a message change with the version. 2.1.312 passed on 15 November 2026, on a Mac
    /// with Apple silicon. The values are `platforms.<kind>.checksum` of
    /// `https://downloads.claude.ai/claude-code-releases/<number>/manifest.json`, read on 14 November 2026.
    public static let tested = [
        Tested(number: "2.1.312", sha256: [
            "darwin-arm64": "6b5ec691195e551b02c41df9f7d723f4ea61eaa03c2df90acefe3736f1aeb620",
            "darwin-x64": "9534770e162cfd6e39301d9ab775affce214df032a68484085bdbab966a7f8cf",
        ]),
    ]

    /// This Mac's kind, by the provider's name.
    public static var kind: String {
        #if arch(arm64)
        "darwin-arm64"
        #else
        "darwin-x64"
        #endif
    }

    public enum Refusal: Error, Equatable, Sendable {
        /// No file is there, or it cannot be read.
        case missing
        /// Its SHA-256 is not on the list.
        case notTested
        /// Its code signature is not a Developer ID of the provider's team.
        case wrongSigner
    }

    /// A file that passed both checks, and the tested version that it is.
    public struct File: Equatable, Sendable {
        public let url: URL
        public let version: String
        /// The copy in the app's own folder. false: the owner's own program.
        public let appsOwn: Bool
    }

    /// What the checks read with: this Mac's own, or a test's.
    public struct Checker: Sendable {
        public var tested: [Tested]
        public var kind: String
        /// The SHA-256 of a file in hex, or nil when it cannot be read.
        public var sha256: @Sendable (URL) -> String?
        /// Whether the file's code signature is valid and is a Developer ID of the provider's team.
        public var signedByProvider: @Sendable (URL) -> Bool

        public init(tested: [Tested] = GuideProgram.tested, kind: String = GuideProgram.kind,
                    sha256: @escaping @Sendable (URL) -> String? = GuideProgram.sha256(of:),
                    signedByProvider: @escaping @Sendable (URL) -> Bool = { GuideProgram.isSigned($0, team: GuideProgram.team) }) {
            self.tested = tested; self.kind = kind; self.sha256 = sha256; self.signedByProvider = signedByProvider
        }

        public static let mac = Checker()
    }

    /// **The two checks of one file.** A file of the app's own folder that fails is deleted: it is a download that
    /// went wrong or a file that changed. The owner's own file is never changed and never deleted.
    public static func check(_ file: URL, appsOwn: Bool, with checker: Checker = .mac) -> Result<File, Refusal> {
        // Through each link: `~/.local/bin/claude` is a link to the version's file, and the file is what is started.
        let real = file.resolvingSymlinksInPath()
        func refuse(_ why: Refusal) -> Result<File, Refusal> {
            if appsOwn { try? FileManager.default.removeItem(at: file) }
            return .failure(why)
        }
        guard let sum = checker.sha256(real) else { return .failure(.missing) }
        guard let version = checker.tested.first(where: { $0.sha256[checker.kind] == sum }) else { return refuse(.notTested) }
        guard checker.signedByProvider(real) else { return refuse(.wrongSigner) }
        return .success(File(url: real, version: version.number, appsOwn: appsOwn))
    }

    /// Where the owner's own program can be, in the order that the app looks: the link that the provider's installer
    /// makes, then that installer's own folder of versions, for each tested number.
    public static func ownersPlaces(home: URL, tested: [Tested] = GuideProgram.tested) -> [URL] {
        [home.appendingPathComponent(".local/bin/claude")]
            + tested.map { home.appendingPathComponent(".local/share/claude/versions/\($0.number)") }
    }

    /// The app's own copy of a version, in the guide's folder.
    public static func appsOwnPlace(_ number: String, in places: GuidePlaces) -> URL {
        places.program.appendingPathComponent("claude-\(number)")
    }

    /// **The program for a start, checked now**: the owner's own when it is a tested version, else the app's own copy
    /// of one. nil when this Mac has neither: the app then gets one (`fetch`).
    public static func find(home: URL, places: GuidePlaces, with checker: Checker = .mac) -> File? {
        for place in ownersPlaces(home: home, tested: checker.tested) {
            if case .success(let file) = check(place, appsOwn: false, with: checker) { return file }
        }
        for version in checker.tested {
            if case .success(let file) = check(appsOwnPlace(version.number, in: places), appsOwn: true, with: checker) {
                return file
            }
        }
        return nil
    }

    /// Where the provider publishes the file of a version for a kind of Mac.
    public static func address(_ number: String, kind: String) -> URL {
        URL(string: "https://downloads.claude.ai/claude-code-releases/\(number)/\(kind)/claude")!
    }

    /// Gets a file from an address into a place: `URLSession` in the app, a stand-in in the tests.
    public typealias Download = @Sendable (_ from: URL, _ to: URL) async throws -> Void

    /// **Gets the newest tested version into the app's own folder**, and checks it there. The file is written beside
    /// its place and moved into it only when both checks passed, so a download that stops leaves no program. It is
    /// about 276 MB.
    public static func fetch(places: GuidePlaces, with checker: Checker = .mac,
                             download: Download = GuideProgram.download) async throws -> File {
        guard let version = checker.tested.last else { throw Refusal.notTested }
        try places.make()
        try FileManager.default.createDirectory(at: places.program, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let coming = places.program.appendingPathComponent("coming-\(UUID().uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: coming) }
        try await download(address(version.number, kind: checker.kind), coming)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: coming.path)
        // `coming` is in the app's own folder, so a file that fails a check is deleted by the check itself.
        _ = try check(coming, appsOwn: true, with: checker).get()
        let place = appsOwnPlace(version.number, in: places)
        try? FileManager.default.removeItem(at: place)
        try FileManager.default.moveItem(at: coming, to: place)
        return try check(place, appsOwn: true, with: checker).get()
    }

    /// The app's own download: the file as the provider serves it, with no change.
    public static let download: Download = { from, to in
        let (file, answer) = try await URLSession.shared.download(from: from)
        defer { try? FileManager.default.removeItem(at: file) }
        guard (answer as? HTTPURLResponse)?.statusCode == 200 else { throw Refusal.missing }
        try FileManager.default.moveItem(at: file, to: to)
    }

    /// **The app's own copy goes at the guide's end** (section 3.6). The owner's own program stays.
    public static func removeAppsOwn(in places: GuidePlaces) {
        try? FileManager.default.removeItem(at: places.program)
    }

    // MARK: - The two reads

    /// The SHA-256 of a file in hex, read in parts: the program's file is some hundred megabytes.
    public static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        do {
            // The read gives nothing at the file's end.
            while let part = try handle.read(upToCount: 4 * 1024 * 1024), !part.isEmpty { hash.update(data: part) }
        } catch {
            return nil
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// What a file's code signature must satisfy: Apple's own anchor, the two marks of a Developer ID certificate, and
    /// that team.
    static func requirement(team: String) -> String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
            + "and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Apple's own check of a file against that requirement, for each architecture in it.
    public static func isSigned(_ file: URL, team: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(file as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(Self.requirement(team: team) as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }
}
#endif
