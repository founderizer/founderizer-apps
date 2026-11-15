import Darwin
import Foundation

/// **The one path to the program that stays true**: the link `~/.founderizer/cli` (the folder with mode 700) to
/// `Contents/MacOS/founderizer-cli` of the app's own bundle, which the app keeps at each start (the plan's section 3.1).
/// A client's configuration names the link's whole path, so it reaches the program of the app that is installed now.
///
/// The app sets the link only from a copy that is signed with the Developer ID, that macOS did not move to a place of
/// its own for the first open (App Translocation), and that was started with no `-hubAddress`; and it replaces a link
/// only when the link's program is gone or belongs to an app with a lower build. So a test build never gives the
/// owner's own agent its program.
public enum CLILink {
    /// What stands at the link's place now.
    public enum Existing: Equatable, Sendable {
        /// Nothing.
        case none
        /// A link: whether it points at this app's own program, whether its program exists, and the build of the app
        /// that holds it (nil when that cannot be read).
        case link(pointsHere: Bool, targetExists: Bool, targetBuild: Int?)
        /// Something that is no link: it is never touched.
        case other
    }

    public enum Step: Equatable, Sendable {
        case keep
        case set
        case replace
    }

    /// **The decision, with no reads of its own.**
    public static func step(signedWithDeveloperID: Bool, translocated: Bool, hubAddressArgument: Bool,
                            programInBundle: Bool, ownBuild: Int?, existing: Existing) -> Step {
        guard signedWithDeveloperID, !translocated, !hubAddressArgument, programInBundle, let ownBuild else {
            return .keep
        }
        switch existing {
        case .none: return .set
        case .other: return .keep
        case .link(let pointsHere, let targetExists, let targetBuild):
            if pointsHere { return .keep }
            if !targetExists { return .replace }
            if let targetBuild, targetBuild < ownBuild { return .replace }
            return .keep
        }
    }

    /// Whether a bundle runs from the place that macOS made for a download's first open.
    public static func translocated(_ bundle: URL) -> Bool { bundle.path.contains("/AppTranslocation/") }

    /// **Keeps the link for this bundle.** Every failure leaves things as they are and says nothing: no screen, no
    /// alert and no line that a person reads. Returns the step that it took, for a test.
    @discardableResult
    public static func keep(bundle: URL, home: URL, signedWithDeveloperID: Bool, hubAddressArgument: Bool) -> Step {
        let manager = FileManager.default
        let program = bundle.appendingPathComponent("Contents/MacOS/founderizer-cli")
        let folder = home.appendingPathComponent(".founderizer", isDirectory: true)
        let link = folder.appendingPathComponent("cli")
        let ownProgram = ProgramPlace.realPath(program.path)
        let step = Self.step(signedWithDeveloperID: signedWithDeveloperID, translocated: translocated(bundle),
                             hubAddressArgument: hubAddressArgument, programInBundle: ownProgram != nil,
                             ownBuild: ProgramPlace.build(of: bundle), existing: existing(at: link, own: ownProgram))
        guard step != .keep, let ownProgram else { return .keep }
        do {
            var directory: ObjCBool = false
            if manager.fileExists(atPath: folder.path, isDirectory: &directory) {
                guard directory.boolValue else { return .keep }     // a file in the folder's place: never touched
                chmod(folder.path, 0o700)
            } else {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            }
            // A link beside the place, then one rename over it: the place never holds nothing or half a link.
            let staged = folder.appendingPathComponent(".cli-\(UUID().uuidString.lowercased())")
            try manager.createSymbolicLink(atPath: staged.path, withDestinationPath: ownProgram)
            guard rename(staged.path, link.path) == 0 else {
                try? manager.removeItem(at: staged)
                return .keep
            }
            return step
        } catch {
            return .keep
        }
    }

    /// What stands at the link's place, read without following it.
    static func existing(at link: URL, own: String?) -> Existing {
        var info = stat()
        guard lstat(link.path, &info) == 0 else { return .none }
        guard info.st_mode & S_IFMT == S_IFLNK else { return .other }
        guard let target = ProgramPlace.realPath(link.path) else {
            return .link(pointsHere: false, targetExists: false, targetBuild: nil)
        }
        let build = ProgramPlace.bundle(of: URL(fileURLWithPath: target)).flatMap(ProgramPlace.build(of:))
        return .link(pointsHere: target == own, targetExists: true, targetBuild: build)
    }
}
