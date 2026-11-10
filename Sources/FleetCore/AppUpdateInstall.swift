#if os(macOS)
import CryptoKit
import Foundation
import Security

/// Taking a checked Mac build and putting it in place of this one (the owner's requirement 10).
///
/// Nothing here runs by itself. The owner presses Update, and this is what that press does: download the zip the
/// manifest named, check its size and its checksum, unpack it, check that the bundle inside is the one the
/// manifest described and is signed by whoever signed the app that is running, and only then move it into place.
/// Every step can fail, and a step that fails leaves the Mac exactly as it was — the app the owner is using is
/// moved aside for the length of one rename, and put back if the new one does not land.
///
/// **Two signatures, both of them necessary.** The Ed25519 signature on the manifest says that our channel sent
/// this build; Apple's own code signature on the bundle says that the owner's Developer ID made it. A channel
/// that is taken over can change the manifest but cannot produce a bundle Apple's check accepts, and a build
/// signed by somebody else cannot be announced by our channel. This is what Sparkle's EdDSA key buys, bought
/// instead with the notarization the product already needs.
public struct AppUpdateInstaller: Sendable {
    /// The application bundle to replace: this app's own, unless a test says otherwise.
    public let bundle: URL
    /// What the new bundle must call itself. A build that is not Founderizer is never put in Founderizer's place.
    public let identifier: String
    /// The Apple Developer team that signed the app that is running, or nil when it is signed ad hoc — a build
    /// made on the owner's own Mac, before the Apple paperwork of `APPLE-SETUP.md` is done. The new build must
    /// match: ad hoc accepts ad hoc, Developer ID accepts that one team and nothing else.
    public let team: String?
    /// The code-signature check. The real one is Apple's; a test puts its own here, because this package ships no
    /// signed build to check against.
    private let verifyCode: @Sendable (URL, String) throws -> Void
    private let download: @Sendable (URL, Int, @Sendable @escaping (Double) -> Void) async throws -> URL

    public init(bundle: URL = Bundle.main.bundleURL,
                identifier: String = Bundle.main.bundleIdentifier ?? "com.founderizer.app",
                team: String? = AppUpdateInstaller.signingTeam(of: Bundle.main.bundleURL),
                verifyCode: (@Sendable (URL, String) throws -> Void)? = nil,
                download: (@Sendable (URL, Int, @Sendable @escaping (Double) -> Void) async throws -> URL)? = nil) {
        self.bundle = bundle
        self.identifier = identifier
        self.team = team
        self.verifyCode = verifyCode ?? AppUpdateInstaller.checkSignature
        self.download = download ?? AppUpdateInstaller.fetch
    }

    /// Where an update stands, for the one line under the button.
    public enum Step: Equatable, Sendable {
        /// 0 to 1, or -1 when the channel did not say how big the download is.
        case downloading(Double)
        case checking
        case installing
        case installed

        public var says: String {
            switch self {
            case .downloading(let part):
                return part < 0 ? "Downloading…" : "Downloading… \(Int(part * 100))%"
            case .checking: return "Checking what was downloaded…"
            case .installing: return "Putting the new Founderizer in place…"
            case .installed: return "Founderizer is updated. It restarts now."
            }
        }
    }

    /// Download, check, and replace. It answers where the new app is, which is where the old one was.
    ///
    /// - Parameter progress: called as each step begins. It is called from a task of this method's, so the screen
    ///   hops to the main actor itself.
    @discardableResult
    public func install(_ manifest: AppManifest,
                        progress: @Sendable @escaping (Step) -> Void = { _ in }) async throws -> URL {
        try canReplace()
        guard let url = URL(string: manifest.url) else { throw AppUpdateFailure.manifest }
        let work = try AppUpdateInstaller.workFolder()
        defer { try? FileManager.default.removeItem(at: work) }

        progress(.downloading(-1))
        let zip = work.appendingPathComponent("Founderizer.zip")
        let downloaded = try await download(url, manifest.size) { progress(.downloading($0)) }
        try? FileManager.default.removeItem(at: zip)
        try FileManager.default.moveItem(at: downloaded, to: zip)

        progress(.checking)
        try AppUpdateInstaller.checkBytes(of: zip, against: manifest)
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        let new = try await AppUpdateInstaller.unpack(zip, into: unpacked)
        try checkBundle(new, against: manifest)
        try verifyCode(new, AppUpdateInstaller.requirement(identifier: identifier, team: team))

        progress(.installing)
        try AppUpdateInstaller.swap(new, over: bundle)
        progress(.installed)
        return bundle
    }

    // ------------------------------------------------------------ what must be true before anything is downloaded

    /// Whether this app can replace itself at all, with the reason when it cannot. The screen asks this before it
    /// offers the button, so the owner is never told to press something that cannot work.
    public func canReplace() throws {
        guard !bundle.path.contains("/AppTranslocation/") else { throw AppUpdateFailure.translocated }
        let parent = bundle.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw AppUpdateFailure.readOnly(parent.path)
        }
    }

    /// nil when this app can replace itself, or the line that says why it cannot.
    public var cannotReplace: String? {
        do { try canReplace(); return nil } catch { return (error as? AppUpdateFailure)?.errorDescription }
    }

    // ------------------------------------------------------------ the checks

    /// The size and the checksum of what was downloaded, against what the signed manifest said they would be.
    static func checkBytes(of file: URL, against manifest: AppManifest) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? nil
        guard size == manifest.size else { throw AppUpdateFailure.size }
        guard try digest(of: file) == manifest.sha256 else { throw AppUpdateFailure.checksum }
    }

    /// The SHA-256 of a file, read in pieces so that a build of any size costs one megabyte of memory.
    static func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let piece = try handle.read(upToCount: 1024 * 1024), !piece.isEmpty { hasher.update(data: piece) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The bundle inside the zip, which must be the one the manifest described. A manifest that names one version
    /// and a bundle that is another is a mismatch, and a mismatch is refused rather than guessed at.
    func checkBundle(_ app: URL, against manifest: AppManifest) throws {
        let read = try AppUpdateInstaller.identity(of: app)
        guard read.identifier == identifier else { throw AppUpdateFailure.notFounderizer(read.identifier) }
        guard read.build == manifest.build, read.version == manifest.version else {
            throw AppUpdateFailure.mismatch(said: "\(manifest.version) (build \(manifest.build))",
                                            found: "\(read.version) (build \(read.build))")
        }
    }

    /// What an application bundle says it is.
    static func identity(of app: URL) throws -> (identifier: String, version: String, build: Int) {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist), data.count <= 1024 * 1024,
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              let version = info["CFBundleShortVersionString"] as? String,
              let build = Int((info["CFBundleVersion"] as? String) ?? "") else {
            throw AppUpdateFailure.unreadableBundle
        }
        return (identifier, version, build)
    }

    /// What the new bundle's code signature must satisfy.
    ///
    /// With a team: Apple's own anchor, our bundle identifier, and that team's certificate — the designated
    /// requirement of a Developer ID build, which nobody else can satisfy. Without one: the identifier alone,
    /// which is all an ad-hoc build can prove, and the screen says as much so that nobody mistakes a development
    /// build for a checked one.
    public static func requirement(identifier: String, team: String?) -> String {
        guard let team, !team.isEmpty else { return "identifier \"\(identifier)\"" }
        return "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Apple's own check of a bundle, against that requirement: every architecture, and the nested code too, so a
    /// changed helper inside the bundle is caught as well as a changed main executable.
    public static func checkSignature(of app: URL, requirement text: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw AppUpdateFailure.unsigned
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw AppUpdateFailure.unsigned }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else { throw AppUpdateFailure.wrongSignature(status) }
    }

    /// The Apple Developer team that signed a bundle, or nil when it is signed ad hoc or not at all.
    public static func signingTeam(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let read = info as? [String: Any] else { return nil }
        let team = read[kSecCodeInfoTeamIdentifier as String] as? String
        return (team?.isEmpty ?? true) ? nil : team
    }

    // ------------------------------------------------------------ the pieces that touch the disk

    /// A folder of this run's own, inside the system's temporary area and readable by nobody else.
    static func workFolder() throws -> URL {
        let work = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("founderizer-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return work
    }

    /// `ditto -x -k`, which is how a Mac unpacks an application zip: it keeps the symbolic links and the extended
    /// attributes that a bundle's code signature is computed over, and `unzip` does not.
    static func unpack(_ zip: URL, into folder: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let answer = try await LocalShell.run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path], timeout: 300)
        guard answer.ok else { throw AppUpdateFailure.cannotUnpack(answer.lines.last ?? "ditto refused the download") }
        let inside = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard inside.count == 1, let app = inside.first else { throw AppUpdateFailure.notOneApp(inside.count) }
        return app
    }

    /// The replacement itself: the old app aside, the new one in its place, the old one to the trash. If the new
    /// one does not land, the old one goes back and the Mac is as it was.
    static func swap(_ new: URL, over old: URL) throws {
        let files = FileManager.default
        let aside = old.deletingLastPathComponent()
            .appendingPathComponent(".\(old.lastPathComponent).replaced-\(UUID().uuidString)")
        try files.moveItem(at: old, to: aside)
        do { try files.moveItem(at: new, to: old) } catch {
            try? files.moveItem(at: aside, to: old)
            throw AppUpdateFailure.cannotReplace(error.localizedDescription)
        }
        if (try? files.trashItem(at: aside, resultingItemURL: nil)) == nil { try? files.removeItem(at: aside) }
    }

    /// The download, straight to a file, with the progress the owner watches. It refuses a body bigger than the
    /// manifest said before it has written it, so a channel that promises ten megabytes cannot send a gigabyte.
    private static let fetch: @Sendable (URL, Int, @Sendable @escaping (Double) -> Void) async throws -> URL = {
        url, size, progress in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: url)
        request.setValue("application/zip", forHTTPHeaderField: "Accept")
        let watcher = DownloadWatcher(expected: size, report: progress)
        let (file, answer) = try await session.download(for: request, delegate: watcher)
        guard let http = answer as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw AppUpdateFailure.download((answer as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return file
    }

    /// The progress of one download, and the one rule the task itself enforces: a body larger than the manifest
    /// promised is stopped while it is arriving.
    private final class DownloadWatcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let expected: Int
        private let report: @Sendable (Double) -> Void

        init(expected: Int, report: @escaping @Sendable (Double) -> Void) {
            self.expected = expected
            self.report = report
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData written: Int64,
                        totalBytesWritten done: Int64, totalBytesExpectedToWrite total: Int64) {
            if done > Int64(expected) { downloadTask.cancel() }
            report(total > 0 ? min(1, Double(done) / Double(total)) : -1)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
    }
}

/// What stopped an update, in the owner's own words. Every one of them leaves this Mac as it was.
public enum AppUpdateFailure: LocalizedError, Equatable, Sendable {
    case manifest
    case translocated
    case readOnly(String)
    case download(Int)
    case size
    case checksum
    case cannotUnpack(String)
    case notOneApp(Int)
    case unreadableBundle
    case notFounderizer(String)
    case mismatch(said: String, found: String)
    case unsigned
    case wrongSignature(OSStatus)
    case cannotReplace(String)

    public var errorDescription: String? {
        switch self {
        case .manifest:
            return "The channel's answer did not name a download this app could fetch."
        case .translocated:
            return "Founderizer is running from a copy macOS made for it, which cannot be replaced. Move "
                + "Founderizer to your Applications folder and open it from there."
        case .readOnly(let folder):
            return "Founderizer cannot write to \(folder), so it cannot replace itself there. Move it to your "
                + "Applications folder, or download the new build yourself."
        case .download(let status):
            return "The download did not start (\(status)). Nothing on this Mac changed."
        case .size:
            return "The download is not the size the signed manifest promised. Nothing was unpacked."
        case .checksum:
            return "The download does not match the checksum our channel signed. It was thrown away and nothing "
                + "on this Mac changed."
        case .cannotUnpack(let says):
            return "The download could not be unpacked: \(says)"
        case .notOneApp(let count):
            return count == 0 ? "The download holds no application." : "The download holds \(count) applications, "
                + "and an update is one."
        case .unreadableBundle:
            return "The application in the download does not say which version it is."
        case .notFounderizer(let identifier):
            return "The download holds \(identifier), which is not Founderizer. Nothing was installed."
        case .mismatch(let said, let found):
            return "Our channel signed \(said) and the download holds \(found). Nothing was installed."
        case .unsigned:
            return "The application in the download carries no code signature this Mac can read."
        case .wrongSignature(let status):
            return "The application in the download is not signed by whoever signed the Founderizer you are "
                + "running (\(status)). Nothing was installed."
        case .cannotReplace(let says):
            return "Founderizer could not be replaced: \(says). The build you were using is back in its place."
        }
    }
}
#endif
