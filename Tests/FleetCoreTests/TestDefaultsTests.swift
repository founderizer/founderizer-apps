import Foundation
import Testing

/// No Mac test leaves a defaults domain in ~/Library/Preferences (TestDefaults says why).
struct TestDefaultsTests {
    /// Only TestDefaults.swift names a defaults domain in the Mac's test targets. A test that names one itself leaves
    /// its plist in ~/Library/Preferences, as DoorHostsTests, DoorAccessTests, DoorKeyReferenceTests, ConnectGateTests
    /// and OwnerDeviceTests did with no removal at all, and every other suite did with `removePersistentDomain(forName:)`;
    /// a test that takes the standard defaults (`UserDefaults.standard`, `in: .standard`) writes the test process's own
    /// plist there, whose values stay for the next run. A copy of the helper in another target is the same file.
    @Test func noOtherTestNamesADefaultsDomain() throws {
        let here = URL(fileURLWithPath: #filePath).standardizedFileURL
        // app/Tests, named in quotes, so that ship.py can run this test for each change of a file in it, once its
        // chooser reads such a folder
        let tests = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests")
        let helper = here.deletingLastPathComponent().appendingPathComponent("TestDefaults.swift")
        let original = try Data(contentsOf: helper)
        let files = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        let named = #/suiteName|PersistentDomain|CFPreferences|\.standard(?![A-Za-z0-9_])|UserDefaults\(\)/#
        var found: [String] = [], seen = false
        for case let file as URL in files where file.pathExtension == "swift" {
            let file = file.standardizedFileURL
            seen = seen || file == here
            if file == here || file == helper { continue }
            if file.lastPathComponent == helper.lastPathComponent, try Data(contentsOf: file) == original { continue }
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains(named) {
                found.append("\(file.path.dropFirst(tests.path.count + 1)):\(index + 1)")
            }
        }
        #expect(seen)       // the folder that was read holds this file
        #expect(found.isEmpty, """
            a test takes TestDefaults("<label>") (FleetCoreTests/TestDefaults.swift; a test of another target takes \
            that file, unchanged, into its target) in place of a domain of its own or the standard defaults: \(found)
            """)
    }

    /// The plist is in the test's own folder, never in ~/Library/Preferences, and the folder is gone once the test
    /// lets go of its defaults: here by a throw, as a failed `#require` does.
    @Test func aTestsDefaultsGoWithTheTest() throws {
        struct Failed: Error {}
        var kept: URL?
        #expect(throws: Failed.self) {
            let defaults = TestDefaults("test-defaults")
            kept = defaults.folder
            defaults.set("a value", forKey: "key")
            #expect(defaults.synchronize())
            #expect(FileManager.default.fileExists(atPath: defaults.folder.appendingPathComponent("defaults.plist").path))
            let preferences = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
                .appendingPathComponent("Library/Preferences")         // where cfprefsd keeps a domain's plain name
            #expect(try FileManager.default.contentsOfDirectory(atPath: preferences.path)
                .filter { $0.contains(defaults.folder.lastPathComponent) }.isEmpty)
            throw Failed()
        }
        let folder = try #require(kept)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
