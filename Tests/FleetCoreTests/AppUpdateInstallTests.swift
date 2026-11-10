#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import FleetCore

/// Putting a checked build in place of the one that is running (the owner's requirement 10).
///
/// These make real bundles, sign them with `codesign` the way the owner's own build does, zip them with `ditto`
/// the way the website will serve them, and run the real checks — Apple's code signature among them. Nothing here
/// is a stand-in except the download itself, which is a local file instead of our channel.
struct AppUpdateInstallTests {
    private static let identifier = "com.founderizer.app.test"

    private func folder() throws -> URL {
        let path = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("app-update-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    /// An application bundle that macOS and `codesign` both accept: a real Mach-O executable and an Info.plist.
    @discardableResult
    private func makeApp(in folder: URL, named name: String = "Founderizer.app",
                         identifier: String = AppUpdateInstallTests.identifier,
                         version: String = "2026.11.1", build: Int = 42, sign: Bool = true) throws -> URL {
        let app = folder.appendingPathComponent(name, isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"),
                                         to: macOS.appendingPathComponent("Founderizer"))
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Founderizer",
                                   "CFBundleName": "Founderizer", "CFBundlePackageType": "APPL",
                                   "CFBundleShortVersionString": version, "CFBundleVersion": String(build)]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if sign { try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) }
        return app
    }

    private func run(_ program: String, _ arguments: [String]) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: program)
        child.arguments = arguments
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        child.waitUntilExit()
        #expect(child.terminationStatus == 0, "\(program) \(arguments.joined(separator: " "))")
    }

    /// The zip our download page will serve: `ditto -c -k --keepParent`, which is what Apple's own notarization
    /// instructions use and what keeps a bundle's signature intact.
    private func zip(_ app: URL, into folder: URL) throws -> URL {
        let zip = folder.appendingPathComponent("Founderizer.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, zip.path])
        return zip
    }

    private func manifest(for zip: URL, version: String = "2026.11.1", build: Int = 42) throws -> AppManifest {
        let size = try #require(FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int)
        return AppManifest(version: version, build: build,
                           url: "https://founderizer.com/downloads/Founderizer.zip",
                           sha256: try AppUpdateInstaller.digest(of: zip), size: size,
                           minimumSystem: "15.0", notes: nil, hold: false, signature: "x")
    }

    // ------------------------------------------------------------ what the new bundle must satisfy

    @Test func theRequirementNamesTheTeamWhenThereIsOne() {
        #expect(AppUpdateInstaller.requirement(identifier: "com.founderizer.app", team: "AB12CD34EF")
                == "anchor apple generic and identifier \"com.founderizer.app\" "
                + "and certificate leaf[subject.OU] = \"AB12CD34EF\"")
        // Before the Apple paperwork is done the app is signed ad hoc, and the identifier is all it can prove.
        #expect(AppUpdateInstaller.requirement(identifier: "com.founderizer.app", team: nil)
                == "identifier \"com.founderizer.app\"")
        #expect(AppUpdateInstaller.requirement(identifier: "com.founderizer.app", team: "")
                == "identifier \"com.founderizer.app\"")
    }

    @Test func applesOwnCheckAcceptsTheRightBundleAndRefusesTheWrongOne() throws {
        let work = try folder()
        defer { try? FileManager.default.removeItem(at: work) }
        let app = try makeApp(in: work)
        try AppUpdateInstaller.checkSignature(of: app,
                                              requirement: AppUpdateInstaller.requirement(identifier: Self.identifier,
                                                                                          team: nil))
        #expect(throws: AppUpdateFailure.self) {
            try AppUpdateInstaller.checkSignature(of: app,
                                                  requirement: AppUpdateInstaller.requirement(identifier: "com.somebody.else",
                                                                                              team: nil))
        }
        // And a Developer ID requirement is not something an ad-hoc build can satisfy.
        #expect(throws: AppUpdateFailure.self) {
            try AppUpdateInstaller.checkSignature(of: app,
                                                  requirement: AppUpdateInstaller.requirement(identifier: Self.identifier,
                                                                                              team: "AB12CD34EF"))
        }
    }

    @Test func aBundleChangedAfterItWasSignedIsRefused() throws {
        let work = try folder()
        defer { try? FileManager.default.removeItem(at: work) }
        let app = try makeApp(in: work)
        try Data("changed".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Founderizer"))
        #expect(throws: AppUpdateFailure.self) {
            try AppUpdateInstaller.checkSignature(of: app,
                                                  requirement: AppUpdateInstaller.requirement(identifier: Self.identifier,
                                                                                              team: nil))
        }
    }

    @Test func anUnsignedBundleIsRefused() throws {
        let work = try folder()
        defer { try? FileManager.default.removeItem(at: work) }
        let app = try makeApp(in: work, sign: false)
        #expect(throws: AppUpdateFailure.self) {
            try AppUpdateInstaller.checkSignature(of: app, requirement: "identifier \"\(Self.identifier)\"")
        }
    }

    // ------------------------------------------------------------ the bytes, and what is inside them

    @Test func theDownloadIsCheckedAgainstTheSignedSizeAndChecksum() throws {
        let work = try folder()
        defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appendingPathComponent("build.zip")
        try Data("the build".utf8).write(to: file)
        let digest = try AppUpdateInstaller.digest(of: file)
        #expect(digest == SHA256.hash(data: Data("the build".utf8)).map { String(format: "%02x", $0) }.joined())

        let right = AppManifest(version: "1", build: 1, url: "https://founderizer.com/a.zip", sha256: digest,
                                size: 9, minimumSystem: nil, notes: nil, hold: false, signature: "x")
        try AppUpdateInstaller.checkBytes(of: file, against: right)

        let wrongSize = AppManifest(version: "1", build: 1, url: right.url, sha256: digest, size: 10,
                                    minimumSystem: nil, notes: nil, hold: false, signature: "x")
        #expect(throws: AppUpdateFailure.size) { try AppUpdateInstaller.checkBytes(of: file, against: wrongSize) }

        let wrongSum = AppManifest(version: "1", build: 1, url: right.url,
                                   sha256: String(repeating: "0", count: 64), size: 9,
                                   minimumSystem: nil, notes: nil, hold: false, signature: "x")
        #expect(throws: AppUpdateFailure.checksum) { try AppUpdateInstaller.checkBytes(of: file, against: wrongSum) }
    }

    @Test func theZipMustHoldExactlyOneApplication() async throws {
        let work = try folder()
        defer { try? FileManager.default.removeItem(at: work) }
        let made = try makeApp(in: work, sign: false)
        let archive = try zip(made, into: work)
        let out = work.appendingPathComponent("one", isDirectory: true)
        let found = try await AppUpdateInstaller.unpack(archive, into: out)
        #expect(found.lastPathComponent == "Founderizer.app")

        let two = try folder()
        defer { try? FileManager.default.removeItem(at: two) }
        try makeApp(in: two, named: "One.app", sign: false)
        try makeApp(in: two, named: "Two.app", sign: false)
        let both = two.appendingPathComponent("both.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", two.path, both.path])
        await #expect(throws: AppUpdateFailure.self) {
            try await AppUpdateInstaller.unpack(both, into: two.appendingPathComponent("out", isDirectory: true))
        }
    }

    @Test func aBundleThatIsNotWhatTheManifestSignedIsRefused() throws {
        let work = try folder()
        defer { try? FileManager.default.removeItem(at: work) }
        let installer = AppUpdateInstaller(bundle: work.appendingPathComponent("Here.app"),
                                           identifier: Self.identifier, team: nil,
                                           verifyCode: { _, _ in }, download: { _, _, _ in work })
        let said = AppManifest(version: "2026.11.1", build: 42, url: "https://founderizer.com/a.zip",
                               sha256: String(repeating: "a", count: 64), size: 1, minimumSystem: nil,
                               notes: nil, hold: false, signature: "x")

        let other = try makeApp(in: work, named: "Other.app", identifier: "com.somebody.else", sign: false)
        #expect(throws: AppUpdateFailure.notFounderizer("com.somebody.else")) {
            try installer.checkBundle(other, against: said)
        }

        let older = try makeApp(in: work, named: "Older.app", version: "2026.10.1", build: 12, sign: false)
        #expect(throws: AppUpdateFailure.mismatch(said: "2026.11.1 (build 42)", found: "2026.10.1 (build 12)")) {
            try installer.checkBundle(older, against: said)
        }

        let right = try makeApp(in: work, named: "Right.app", sign: false)
        try installer.checkBundle(right, against: said)
    }

    // ------------------------------------------------------------ the replacement, and what it leaves behind

    @Test func theOldAppComesBackWhenTheNewOneCannotLand() throws {
        let work = try folder()
        defer { try? FileManager.default.removeItem(at: work) }
        let here = work.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: here, withIntermediateDirectories: true)
        let old = try makeApp(in: here, version: "2026.10.1", build: 12, sign: false)

        #expect(throws: AppUpdateFailure.self) {
            try AppUpdateInstaller.swap(work.appendingPathComponent("nothing-here.app"), over: old)
        }
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(try AppUpdateInstaller.identity(of: old).build == 12)
    }

    @Test func aPressReplacesTheAppThatIsRunning() async throws {
        let work = try folder()
        defer { try? FileManager.default.removeItem(at: work) }
        let here = work.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: here, withIntermediateDirectories: true)
        let old = try makeApp(in: here, version: "2026.10.1", build: 12)

        let source = try folder()
        defer { try? FileManager.default.removeItem(at: source) }
        let new = try makeApp(in: source, version: "2026.11.1", build: 42)
        let archive = try zip(new, into: source)
        let said = try manifest(for: archive)

        // The download is the only stand-in: a copy of that zip, where the channel's bytes would land. Everything
        // after it — the checksum, the unpacking, Apple's own check of the signature, the replacement — is real.
        let installer = AppUpdateInstaller(bundle: old, identifier: Self.identifier, team: nil,
                                           download: { _, _, progress in
                                               progress(0.5)
                                               let copy = source.appendingPathComponent("\(UUID().uuidString).zip")
                                               try FileManager.default.copyItem(at: archive, to: copy)
                                               return copy
                                           })
        let steps = Steps()
        let landed = try await installer.install(said) { steps.note($0) }
        #expect(landed == old)
        #expect(try AppUpdateInstaller.identity(of: old).version == "2026.11.1")
        #expect(try AppUpdateInstaller.identity(of: old).build == 42)
        #expect(steps.seen.contains(.checking))
        #expect(steps.seen.contains(.installing))
        #expect(steps.seen.last == .installed)
        // Nothing of the update is left on the Mac but the app itself.
        let left = try FileManager.default.contentsOfDirectory(atPath: here.path)
        #expect(left == ["Founderizer.app"])
    }

    @Test func aDownloadThatDoesNotMatchTheManifestLeavesTheAppAlone() async throws {
        let work = try folder()
        defer { try? FileManager.default.removeItem(at: work) }
        let here = work.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: here, withIntermediateDirectories: true)
        let old = try makeApp(in: here, version: "2026.10.1", build: 12)

        let source = try folder()
        defer { try? FileManager.default.removeItem(at: source) }
        let new = try makeApp(in: source, version: "2026.11.1", build: 42)
        let archive = try zip(new, into: source)
        var said = try manifest(for: archive)
        said = AppManifest(version: said.version, build: said.build, url: said.url,
                           sha256: String(repeating: "0", count: 64), size: said.size,
                           minimumSystem: said.minimumSystem, notes: said.notes, hold: said.hold,
                           signature: said.signature)

        let installer = AppUpdateInstaller(bundle: old, identifier: Self.identifier, team: nil,
                                           download: { _, _, _ in
                                               let copy = source.appendingPathComponent("\(UUID().uuidString).zip")
                                               try FileManager.default.copyItem(at: archive, to: copy)
                                               return copy
                                           })
        await #expect(throws: AppUpdateFailure.checksum) { try await installer.install(said) }
        #expect(try AppUpdateInstaller.identity(of: old).build == 12)
    }

    @Test func anAppThatCannotReplaceItselfSaysSoBeforeAnythingIsDownloaded() throws {
        let translocated = AppUpdateInstaller(
            bundle: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Founderizer.app"),
            identifier: Self.identifier, team: nil, verifyCode: { _, _ in }, download: { _, _, _ in URL(fileURLWithPath: "/") })
        #expect(translocated.cannotReplace?.contains("Applications folder") == true)

        let work = try folder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: work.path)
            try? FileManager.default.removeItem(at: work)
        }
        let locked = work.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let app = try makeApp(in: locked, sign: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        let readOnly = AppUpdateInstaller(bundle: app, identifier: Self.identifier, team: nil,
                                          verifyCode: { _, _ in }, download: { _, _, _ in URL(fileURLWithPath: "/") })
        #expect(readOnly.cannotReplace?.contains("cannot write to") == true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
    }

    @Test func everyStepHasALineTheOwnerCanRead() {
        #expect(AppUpdateInstaller.Step.downloading(-1).says == "Downloading…")
        #expect(AppUpdateInstaller.Step.downloading(0.5).says == "Downloading… 50%")
        #expect(AppUpdateInstaller.Step.installed.says.contains("updated"))
        #expect(AppUpdateFailure.checksum.errorDescription?.contains("nothing on this Mac changed") == true)
        #expect(AppUpdateFailure.translocated.errorDescription?.contains("Applications folder") == true)
    }

    /// The steps the screen was told about, kept where a `@Sendable` report may write them.
    private final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [AppUpdateInstaller.Step] = []
        func note(_ step: AppUpdateInstaller.Step) {
            lock.lock(); defer { lock.unlock() }
            kept.append(step)
        }
        var seen: [AppUpdateInstaller.Step] { lock.lock(); defer { lock.unlock() }; return kept }
    }
}
#endif
