#if os(macOS)
import Foundation
import Testing
@testable import FleetCore

/// The app's place on a Mac (`AppHome`): which start moves the app to Applications, and that the copy is whole.
struct AppHomeTests {
    private static let own = AppHome.Build(identifier: "com.example.app", number: 187)
    private static let onImage = "/Volumes/Founderizer/Founderizer.app"

    private func folder() throws -> URL {
        let path = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("app-home-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    /// A folder that reads as an application bundle: its Info.plist and one file beside it.
    @discardableResult
    private func makeApp(in folder: URL, identifier: String = "com.example.app", build: String? = "187",
                         holds: String = "new") throws -> URL {
        let app = folder.appendingPathComponent("Founderizer.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS", isDirectory: true),
                                                withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": identifier]
        if let build { info["CFBundleVersion"] = build }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data(holds.utf8).write(to: contents.appendingPathComponent("MacOS/Founderizer"))
        return app
    }

    private func holds(_ app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/MacOS/Founderizer"), encoding: .utf8)
    }

    // MARK: the decision

    @Test func anAppOnADiskImageGoesToAnEmptyPlace() {
        #expect(AppHome.step(path: Self.onImage, onReadOnlyVolume: true, own: Self.own, somethingThere: false, there: nil)
                == .copy(replaces: false))
    }

    @Test func anAppInAFolderOfTheMacStays() {
        for path in ["/Applications/Founderizer.app", "/Users/owner/Downloads/Founderizer.app",
                     "/private/var/folders/ab/T/AppTranslocation/1234/d/Founderizer.app"] {
            #expect(AppHome.step(path: path, onReadOnlyVolume: false, own: Self.own, somethingThere: false, there: nil)
                    == .stay)
        }
    }

    /// A volume of the customer's own that can be written, an external disk, is a place they chose.
    @Test func anAppOnAVolumeThatCanBeWrittenStays() {
        #expect(AppHome.step(path: "/Volumes/Work/Founderizer.app", onReadOnlyVolume: false, own: Self.own,
                             somethingThere: false, there: nil) == .stay)
    }

    /// The system's own volume cannot be written either, and neither can the place where macOS runs a download from
    /// (`AppTranslocation`, a read-only mount): neither is a disk image.
    @Test func aReadOnlyPlaceThatIsNoMountedVolumeStays() {
        for path in ["/System/Applications/Founderizer.app",
                     "/private/var/folders/ab/T/AppTranslocation/1234/d/Founderizer.app"] {
            #expect(AppHome.step(path: path, onReadOnlyVolume: true, own: Self.own, somethingThere: false, there: nil)
                    == .stay)
        }
    }

    /// The app in Applications runs: it is not replaced by a newer build and gets no second instance.
    @Test func anAppThatRunsInApplicationsComesToTheFront() {
        for number in [150, 187, 400] {
            let there = AppHome.Build(identifier: "com.example.app", number: number)
            #expect(AppHome.step(path: Self.onImage, onReadOnlyVolume: true, own: Self.own, somethingThere: true,
                                 there: there, runsThere: true) == .front)
        }
        let other = AppHome.Build(identifier: "com.example.other", number: 1)
        #expect(AppHome.step(path: Self.onImage, onReadOnlyVolume: true, own: Self.own, somethingThere: true,
                             there: other, runsThere: true) == .stay)
    }

    /// A start from a folder of the Mac asks nothing of the app: no look for an instance that runs, no copy.
    @Test func aStartThatIsNotOnADiskImageAsksNothing() throws {
        let root = try folder(), applications = try folder()
        defer { for path in [root, applications] { try? FileManager.default.removeItem(at: path) } }
        let app = try makeApp(in: root)
        let place = applications.appendingPathComponent("Founderizer.app", isDirectory: true)
        var asked = false
        #expect(!AppHome.settle(bundle: app, installed: place, arguments: [], runsThere: { _ in asked = true; return true }))
        #expect(!asked)
        #expect(!FileManager.default.fileExists(atPath: place.path))
    }

    @Test func anAppThatCannotReadItsOwnBuildStays() {
        #expect(AppHome.step(path: Self.onImage, onReadOnlyVolume: true, own: nil, somethingThere: false, there: nil)
                == .stay)
    }

    @Test func anOlderBuildInApplicationsIsReplaced() {
        let there = AppHome.Build(identifier: "com.example.app", number: 186)
        #expect(AppHome.step(path: Self.onImage, onReadOnlyVolume: true, own: Self.own, somethingThere: true, there: there)
                == .copy(replaces: true))
    }

    @Test func theSameOrANewerBuildInApplicationsOpens() {
        for number in [187, 188, 400] {
            let there = AppHome.Build(identifier: "com.example.app", number: number)
            #expect(AppHome.step(path: Self.onImage, onReadOnlyVolume: true, own: Self.own, somethingThere: true,
                                 there: there) == .open)
        }
    }

    /// Something else has the name: this app neither replaces it nor opens it.
    @Test func anotherProgramWithTheNameIsLeftAlone() {
        let other = AppHome.Build(identifier: "com.example.other", number: 1)
        #expect(AppHome.step(path: Self.onImage, onReadOnlyVolume: true, own: Self.own, somethingThere: true, there: other)
                == .stay)
        #expect(AppHome.step(path: Self.onImage, onReadOnlyVolume: true, own: Self.own, somethingThere: true, there: nil)
                == .stay)
    }

    // MARK: what a bundle says

    @Test func aBundleGivesItsIdentifierAndBuild() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(in: root, identifier: "com.example.app", build: "189")
        #expect(AppHome.Build(bundle: app) == AppHome.Build(identifier: "com.example.app", number: 189))
    }

    @Test func aFolderWithNoBuildNumberIsNoBundle() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AppHome.Build(bundle: root.appendingPathComponent("Nothing.app")) == nil)
        #expect(AppHome.Build(bundle: try makeApp(in: root, build: nil)) == nil)
        let words = try folder()
        defer { try? FileManager.default.removeItem(at: words) }
        #expect(AppHome.Build(bundle: try makeApp(in: words, build: "one")) == nil)
    }

    // MARK: the copy

    @Test func theAppIsCopiedToAnEmptyPlaceAndStaysWhereItWas() throws {
        let image = try folder(), applications = try folder()
        defer { for path in [image, applications] { try? FileManager.default.removeItem(at: path) } }
        let app = try makeApp(in: image)
        let place = applications.appendingPathComponent("Founderizer.app", isDirectory: true)

        #expect(AppHome.place(app, at: place, replaces: false))
        #expect(holds(place) == "new")
        #expect(holds(app) == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["Founderizer.app"])
    }

    @Test func anOlderBuildGoesAwayOnlyForTheNewOne() throws {
        let image = try folder(), applications = try folder()
        defer { for path in [image, applications] { try? FileManager.default.removeItem(at: path) } }
        let app = try makeApp(in: image, build: "187", holds: "new")
        let place = try makeApp(in: applications, build: "186", holds: "old")

        #expect(AppHome.place(app, at: place, replaces: true))
        #expect(holds(place) == "new")
        #expect(AppHome.Build(bundle: place)?.number == 187)
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["Founderizer.app"])
    }

    /// A user who cannot write to the folder keeps what is there, and the app goes on from the disk image.
    @Test func aFolderThatCannotBeWrittenKeepsWhatItHolds() throws {
        let image = try folder(), applications = try folder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: applications.path)
            for path in [image, applications] { try? FileManager.default.removeItem(at: path) }
        }
        let app = try makeApp(in: image, build: "187", holds: "new")
        let place = try makeApp(in: applications, build: "186", holds: "old")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: applications.path)

        #expect(!AppHome.place(app, at: place, replaces: true))
        #expect(holds(place) == "old")
        #expect(!AppHome.place(app, at: applications.appendingPathComponent("Other.app"), replaces: false))
    }

    /// The place was taken between the decision and the copy: nothing is written over it. When what took it is this
    /// same build, the copy counts as made, and that one opens.
    @Test func aPlaceThatWasTakenMeanwhileIsNotWrittenOver() throws {
        let image = try folder(), applications = try folder(), others = try folder()
        defer { for path in [image, applications, others] { try? FileManager.default.removeItem(at: path) } }
        let app = try makeApp(in: image, build: "187", holds: "new")
        let older = try makeApp(in: applications, build: "186", holds: "theirs")
        #expect(!AppHome.place(app, at: older, replaces: false))
        #expect(holds(older) == "theirs")

        let same = try makeApp(in: others, build: "187", holds: "theirs")
        #expect(AppHome.place(app, at: same, replaces: false))
        #expect(holds(same) == "theirs")
    }

    // MARK: the address of no hub

    @Test func theAddressOfNoHubIsKnownInEachSpelling() throws {
        #expect(HubClient.isUnset(try HubClient.address(HubClient.defaultAddress)))
        #expect(HubClient.isUnset(try #require(URL(string: "http://FLEET.invalid:8765/"))))
        #expect(!HubClient.isUnset(try HubClient.address("http://100.84.1.2:8765")))
        #expect(!HubClient.isUnset(try HubClient.address("http://fleet.invalid:9000")))
    }
}
#endif
