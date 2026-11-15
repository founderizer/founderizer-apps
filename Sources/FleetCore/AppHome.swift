#if os(macOS)
import Foundation

/// **The app's place on this Mac is the Applications folder, and a start from the disk image puts it there.**
///
/// A new customer opens Founderizer in the window of the disk image that they downloaded, and it ran from there (the
/// onboarding test of 13 November 2026, on a clean Mac: the process was `/Volumes/Founderizer/Founderizer.app`). The
/// disk image goes away at a restart, so the app was then nowhere on the Mac: not in Applications, not in the Dock.
/// Each new mount brought macOS's question about a download again, and an update could not be put in place there
/// (`AppUpdateFailure.readOnly`). The Mac installer has copied itself in the same way since its first release.
///
/// So a start from a disk image copies the app to Applications, and that copy opens in this one's place: no question
/// and no press, because the copy is the app that the customer opened a moment ago. A start from any other place does
/// nothing here, so a Mac that already has the app is not touched.
public enum AppHome {
    /// Where the app stays.
    public static let installed = URL(fileURLWithPath: "/Applications/Founderizer.app", isDirectory: true)

    /// What a start does about the app's place.
    public enum Step: Equatable, Sendable {
        /// It goes on from where it stands.
        case stay
        /// Applications holds a build that is the same or newer: that one opens.
        case open
        /// The app in Applications runs now: it comes to the front, and nothing is copied over it.
        case front
        /// This app goes to Applications, over an older build when `replaces`, and the copy opens.
        case copy(replaces: Bool)
    }

    /// What this decision reads of a bundle.
    public struct Build: Equatable, Sendable {
        public let identifier: String
        public let number: Int

        public init(identifier: String, number: Int) {
            self.identifier = identifier
            self.number = number
        }

        /// nil for a folder that is no application bundle with a build number.
        public init?(bundle: URL) {
            let file = bundle.appendingPathComponent("Contents/Info.plist")
            guard let info = NSDictionary(contentsOf: file),
                  let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty,
                  let number = (info["CFBundleVersion"] as? String).flatMap({ Int($0) }) else { return nil }
            self.init(identifier: identifier, number: number)
        }
    }

    /// **The decision, with no reads of its own.** Only an app on a mounted volume that cannot be written moves: that
    /// is a disk image. An app in a folder of the Mac stays there, also when the folder is not Applications, because
    /// the customer put it there. A copy that macOS made to run a download from (`AppTranslocation`) is not on such a
    /// volume, so it stays too.
    ///
    /// - `there`: the bundle at the place in Applications, nil when nothing is there. A bundle of another program with
    ///   that name is never replaced or opened, and neither is one that this cannot read.
    /// - `runsThere`: the app at that place runs now. Then it is never replaced, also by a newer build, because a
    ///   bundle that changes under a running app breaks it, and no second instance starts beside it: two of them
    ///   would read and write one fleet. The app that runs updates itself.
    public static func step(path: String, onReadOnlyVolume: Bool, own: Build?, somethingThere: Bool, there: Build?,
                            runsThere: Bool = false) -> Step {
        guard onReadOnlyVolume, path.hasPrefix("/Volumes/"), let own else { return .stay }
        guard somethingThere else { return .copy(replaces: false) }
        guard let there, there.identifier == own.identifier else { return .stay }
        if runsThere { return .front }
        return there.number >= own.number ? .open : .copy(replaces: true)
    }

    /// **Puts the app in its place when it stands on a disk image.**
    ///
    /// - `runsThere`: whether the app at the place runs now. The app gives it, because the answer needs AppKit and
    ///   this library has none. It is asked only for an app on a disk image.
    /// - Returns: true when the app in Applications opens or comes to the front in this one's place, so this process
    ///   must end; false when this app goes on from where it stands. Every failure is false: a user who cannot write
    ///   to Applications uses the app from the disk image, as before.
    public static func settle(bundle: URL = Bundle.main.bundleURL, installed: URL = AppHome.installed,
                              arguments: [String] = Array(CommandLine.arguments.dropFirst()),
                              runsThere: (URL) -> Bool = { _ in false }) -> Bool {
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
        // Every other start ends here, before any more reads.
        guard readOnly, bundle.path.hasPrefix("/Volumes/") else { return false }
        let exists = FileManager.default.fileExists(atPath: installed.path)
        let opened: Bool
        switch step(path: bundle.path, onReadOnlyVolume: readOnly, own: Build(bundle: bundle),
                    somethingThere: exists, there: Build(bundle: installed), runsThere: exists && runsThere(installed)) {
        case .stay: return false
        // macOS brings an app that runs to the front when it is opened again, and starts no second one.
        case .front: opened = run("/usr/bin/open", [installed.path])
        case .open: opened = open(installed, arguments: arguments)
        case .copy(let replaces):
            opened = place(bundle, at: installed, replaces: replaces) && open(installed, arguments: arguments)
        }
        if opened { eject(imageOf: bundle) }
        return opened
    }

    /// **The disk image goes away once the app in Applications runs** (the owner's yes of 14 November 2026: the app
    /// "copies itself to Applications and ejects the disk image"). Its window and the disk on the desktop would
    /// otherwise stay until a restart, with a second copy of the app in them. Only a volume that `hdiutil` lists as a
    /// disk image is ejected: a read-only drive of the customer's own is never touched.
    ///
    /// A volume that runs a program cannot be detached, and this process runs from it until `settle` returns. So a
    /// shell of its own waits for this process to end and then detaches the volume. It looks every tenth of a second,
    /// at most 600 times, and a detach that fails (Finder copies from the image, say) leaves it mounted, as before.
    static func eject(imageOf bundle: URL) {
        guard let volume = (try? bundle.resourceValues(forKeys: [.volumeURLKey]))?.volume,
              let info = output("/usr/bin/hdiutil", ["info", "-plist"]),
              isDiskImage(volume: volume.path, hdiutilInfo: info) else { return }
        let wait = #"(n=0; while kill -0 "$1" 2>/dev/null && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n+1)); done; "#
            + #"/usr/bin/hdiutil detach -quiet "$2") </dev/null >/dev/null 2>&1 &"#
        _ = run("/bin/sh", ["-c", wait, "eject", String(ProcessInfo.processInfo.processIdentifier), volume.path])
    }

    /// Whether `hdiutil info -plist` lists a disk image mounted at this volume.
    static func isDiskImage(volume: String, hdiutilInfo: Data) -> Bool {
        func bare(_ path: String) -> String {
            path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        guard let info = try? PropertyListSerialization.propertyList(from: hdiutilInfo, format: nil) as? [String: Any],
              let images = info["images"] as? [[String: Any]] else { return false }
        let wanted = bare(volume)
        return images.contains { image in
            (image["system-entities"] as? [[String: Any]] ?? []).contains {
                ($0["mount-point"] as? String).map(bare) == wanted
            }
        }
    }

    /// **The copy, whole or not at all.** The app is copied to a folder beside its place first and moved from there, so
    /// an older build goes away only when the new one is complete, and a copy that stops halfway leaves nothing in
    /// Applications. The copy loses the mark of a download: the customer answered macOS's question about this same app
    /// when they opened it, and the mark on the copy would ask it a second time.
    static func place(_ bundle: URL, at installed: URL, replaces: Bool) -> Bool {
        let manager = FileManager.default
        guard let room = try? manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installed,
                                          create: true) else { return false }
        defer { try? manager.removeItem(at: room) }
        let staged = room.appendingPathComponent(installed.lastPathComponent, isDirectory: true)
        do {
            try manager.copyItem(at: bundle, to: staged)
            _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
            if replaces {
                _ = try manager.replaceItemAt(installed, withItemAt: staged)
            } else {
                try manager.moveItem(at: staged, to: installed)
            }
            return true
        } catch {
            // A replacement can put the new build in place and then fail to remove the old one: the place tells.
            guard let now = Build(bundle: installed), let own = Build(bundle: bundle) else { return false }
            return now == own
        }
    }

    /// Opens the copy as a new instance, with the arguments of this start, while this process still runs: this
    /// process has the same identifier, and without `-n` macOS can take it for the app that already runs.
    private static func open(_ app: URL, arguments: [String]) -> Bool {
        run("/usr/bin/open", ["-n", app.path] + (arguments.isEmpty ? [] : ["--args"] + arguments))
    }

    /// Runs a tool of macOS to its end and gives what it printed; nil when it did not end with 0.
    private static func output(_ tool: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    /// Runs a tool of macOS to its end. true when it ended with 0.
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
#endif
