import Foundation
import Testing

/// The defaults of one test: a domain whose plist is in a temporary folder of its own, and the folder goes when the
/// test lets go of its defaults, also after a failure.
///
/// A domain with a plain name (`UserDefaults(suiteName: "door-hosts-…")`) keeps its plist in ~/Library/Preferences,
/// and cfprefsd writes it there again after the test removed it: `removePersistentDomain(forName:)` leaves an empty
/// plist, and when the test deletes that file too, cfprefsd writes it back a few seconds later, and again after the
/// test process ends (measured on 20 November 2026: 50 of 50 domains, within 4 to 6 seconds, also after
/// `synchronize()`). At 22:20 UTC that day the folder held 5,954 files, 5,256 of them from these tests, while the
/// owner's Mac had no memory left for a Swift build. A domain whose name is an absolute path keeps its plist at that
/// path, and nothing writes it again once its folder is gone (measured the same day). So this object is the test's
/// defaults, and its `deinit` removes the folder: a test needs no `defer`, and one that throws loses its defaults the
/// same way. A test process that crashes leaves the folder in the temporary folder, as it leaves its other files
/// there. TestDefaultsTests holds it; a test of another target that needs defaults takes this file into its target.
final class TestDefaults: UserDefaults, @unchecked Sendable {
    /// `<label>-<UUID>` in the temporary folder: the label says which test made a folder that a crash left.
    let folder: URL

    init(_ label: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)",
                                                                                  isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Issue.record(error, "cfprefsd makes no folder: with none, no value of the test reaches a file")
        }
        self.folder = folder
        super.init(suiteName: folder.appendingPathComponent("defaults").path)!
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }
}
