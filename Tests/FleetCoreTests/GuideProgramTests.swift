#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import FleetCore

/// **The program's file and its two checks** (`GuideProgram`), and the sign-in's answer (`GuideSignIn`). Each test has a
/// scratch home and a scratch folder of the guide, with stand-in files: no test starts the provider's program, gets a
/// file from the network or reads the owner's own program.
struct GuideProgramTests {
    private final class Scratch {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guide-program-\(UUID().uuidString)")
        var home: URL { root.appendingPathComponent("home") }
        var places: GuidePlaces { GuidePlaces(root: root.appendingPathComponent("guide")) }

        init() throws { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func file(_ url: URL, _ text: String) throws -> URL {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    }

    private static func sum(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A checker whose list has the given texts as its tested files, and whose signer is the provider for each file
    /// but the ones named.
    private static func checker(tested: [String: String], otherSigner: Set<String> = []) -> GuideProgram.Checker {
        GuideProgram.Checker(tested: tested.keys.sorted().map { GuideProgram.Tested(number: $0, sha256: ["test-kind": sum(tested[$0]!)]) },
                             kind: "test-kind",
                             signedByProvider: { file in !otherSigner.contains(file.lastPathComponent) })
    }

    // MARK: the list

    @Test func theFirstListHasTheVersionOfTheProbeForBothKindsOfMac() {
        #expect(GuideProgram.tested.map(\.number) == ["2.1.312"])
        for version in GuideProgram.tested {
            #expect(Set(version.sha256.keys) == ["darwin-arm64", "darwin-x64"])
            for sum in version.sha256.values { #expect(sum.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil) }
        }
        #expect(["darwin-arm64", "darwin-x64"].contains(GuideProgram.kind))
        #expect(GuideProgram.address("2.1.312", kind: "darwin-arm64").absoluteString
                == "https://downloads.claude.ai/claude-code-releases/2.1.312/darwin-arm64/claude")
    }

    // MARK: the two checks

    @Test func aTestedFileOfTheProviderPasses() throws {
        let scratch = try Scratch()
        let file = try scratch.file(scratch.home.appendingPathComponent("claude"), "version one")
        let checked = try GuideProgram.check(file, appsOwn: false, with: Self.checker(tested: ["1.0.1": "version one"])).get()
        #expect(checked.version == "1.0.1")
        #expect(checked.appsOwn == false)
        #expect(checked.url.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
    }

    @Test func aFileWhoseSHA256IsNotOnTheListIsRefusedAndTheOwnersFileStays() throws {
        let scratch = try Scratch()
        let file = try scratch.file(scratch.home.appendingPathComponent(".local/bin/claude"), "a newer version")
        #expect(GuideProgram.check(file, appsOwn: false, with: Self.checker(tested: ["1.0.1": "version one"])) == .failure(.notTested))
        #expect(scratch.exists(file))
        #expect(try String(contentsOf: file, encoding: .utf8) == "a newer version")
    }

    @Test func aFileWithAnotherSignerIsRefusedAndTheOwnersFileStays() throws {
        let scratch = try Scratch()
        let file = try scratch.file(scratch.home.appendingPathComponent(".local/bin/claude"), "version one")
        let checker = Self.checker(tested: ["1.0.1": "version one"], otherSigner: ["claude"])
        #expect(GuideProgram.check(file, appsOwn: false, with: checker) == .failure(.wrongSigner))
        #expect(scratch.exists(file))
    }

    @Test func aFileOfTheAppsOwnFolderThatFailsIsDeleted() throws {
        let scratch = try Scratch()
        let changed = try scratch.file(GuideProgram.appsOwnPlace("1.0.1", in: scratch.places), "changed")
        #expect(GuideProgram.check(changed, appsOwn: true, with: Self.checker(tested: ["1.0.1": "version one"])) == .failure(.notTested))
        #expect(!scratch.exists(changed))
        let unsigned = try scratch.file(GuideProgram.appsOwnPlace("1.0.1", in: scratch.places), "version one")
        let checker = Self.checker(tested: ["1.0.1": "version one"], otherSigner: ["claude-1.0.1"])
        #expect(GuideProgram.check(unsigned, appsOwn: true, with: checker) == .failure(.wrongSigner))
        #expect(!scratch.exists(unsigned))
    }

    @Test func noFileIsMissing() throws {
        let scratch = try Scratch()
        #expect(GuideProgram.check(scratch.home.appendingPathComponent("none"), appsOwn: false,
                                   with: Self.checker(tested: ["1.0.1": "version one"])) == .failure(.missing))
    }

    @Test func theOwnersLinkIsFollowedToTheFileThatIsStarted() throws {
        let scratch = try Scratch()
        let version = try scratch.file(scratch.home.appendingPathComponent(".local/share/claude/versions/1.0.1"), "version one")
        let link = scratch.home.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: version)
        let checked = try GuideProgram.check(link, appsOwn: false, with: Self.checker(tested: ["1.0.1": "version one"])).get()
        #expect(checked.url.lastPathComponent == "1.0.1")
    }

    // MARK: which file a start takes

    @Test func theOwnersOwnProgramComesFirstWhenItIsATestedVersion() throws {
        let scratch = try Scratch()
        let checker = Self.checker(tested: ["1.0.1": "version one"])
        try scratch.file(scratch.home.appendingPathComponent(".local/bin/claude"), "version one")
        try scratch.file(GuideProgram.appsOwnPlace("1.0.1", in: scratch.places), "version one")
        let found = try #require(GuideProgram.find(home: scratch.home, places: scratch.places, with: checker))
        #expect(found.appsOwn == false)
    }

    @Test func anOwnersProgramOfAnotherVersionIsPassedOverAndNeverChanged() throws {
        let scratch = try Scratch()
        let checker = Self.checker(tested: ["1.0.1": "version one"])
        let owners = try scratch.file(scratch.home.appendingPathComponent(".local/bin/claude"), "a newer version")
        // The installer's own folder still has the tested version, with no link to it.
        try scratch.file(scratch.home.appendingPathComponent(".local/share/claude/versions/1.0.1"), "version one")
        let found = try #require(GuideProgram.find(home: scratch.home, places: scratch.places, with: checker))
        #expect(found.url.lastPathComponent == "1.0.1")
        #expect(found.appsOwn == false)
        #expect(try String(contentsOf: owners, encoding: .utf8) == "a newer version")
    }

    @Test func withNoTestedProgramOfTheOwnersTheAppsOwnCopyIsTaken() throws {
        let scratch = try Scratch()
        let checker = Self.checker(tested: ["1.0.1": "version one"])
        try scratch.file(scratch.home.appendingPathComponent(".local/bin/claude"), "a newer version")
        #expect(GuideProgram.find(home: scratch.home, places: scratch.places, with: checker) == nil)
        try scratch.file(GuideProgram.appsOwnPlace("1.0.1", in: scratch.places), "version one")
        let found = try #require(GuideProgram.find(home: scratch.home, places: scratch.places, with: checker))
        #expect(found.appsOwn)
    }

    // MARK: the app gets a tested version

    @Test func aDownloadThatPassesBothChecksIsTheAppsOwnCopy() async throws {
        let scratch = try Scratch()
        let checker = Self.checker(tested: ["1.0.1": "version one"])
        let file = try await GuideProgram.fetch(places: scratch.places, with: checker) { from, to in
            #expect(from.absoluteString == "https://downloads.claude.ai/claude-code-releases/1.0.1/test-kind/claude")
            try Data("version one".utf8).write(to: to)
        }
        #expect(file.appsOwn)
        #expect(file.version == "1.0.1")
        #expect(file.url.resolvingSymlinksInPath() == GuideProgram.appsOwnPlace("1.0.1", in: scratch.places).resolvingSymlinksInPath())
        #expect(FileManager.default.isExecutableFile(atPath: file.url.path))
        GuideProgram.removeAppsOwn(in: scratch.places)
        #expect(!scratch.exists(scratch.places.program))
    }

    @Test func aDownloadThatFailsACheckLeavesNoProgram() async throws {
        let scratch = try Scratch()
        let checker = Self.checker(tested: ["1.0.1": "version one"])
        await #expect(throws: GuideProgram.Refusal.notTested) {
            try await GuideProgram.fetch(places: scratch.places, with: checker) { _, to in try Data("another file".utf8).write(to: to) }
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: scratch.places.program.path)
        #expect(left.isEmpty)
    }

    // MARK: the real reads of this Mac

    @Test func theSHA256OfAFileIsReadInParts() throws {
        let scratch = try Scratch()
        let file = try scratch.file(scratch.home.appendingPathComponent("some"), "abc")
        #expect(GuideProgram.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(GuideProgram.sha256(of: scratch.home.appendingPathComponent("none")) == nil)
    }

    @Test func aFileThatAppleSignedIsNotTheProvidersAndNeitherIsAFileWithNoSignature() throws {
        // `/bin/ls` has a valid signature of Apple's own, which is no Developer ID of the provider's team.
        #expect(!GuideProgram.isSigned(URL(fileURLWithPath: "/bin/ls"), team: GuideProgram.team))
        let scratch = try Scratch()
        let file = try scratch.file(scratch.home.appendingPathComponent("unsigned"), "#!/bin/sh\n")
        #expect(!GuideProgram.isSigned(file, team: GuideProgram.team))
        #expect(GuideProgram.requirement(team: "Q6L2SF6YDW").contains("certificate leaf[subject.OU] = \"Q6L2SF6YDW\""))
    }

    // MARK: the sign-in

    @Test func aPlansSignInIsAPlanWithItsName() {
        let answer = #"{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "email": "owner@example.com", "subscriptionType": "max"}"#
        #expect(GuideSignIn.read(answer) == GuideSignIn.Status(signedIn: true, account: GuideAccount(kind: .plan, plan: "max")))
    }

    @Test func eachOtherMethodIsAKeyAndNoSignInIsNone() {
        #expect(GuideSignIn.read(#"{"loggedIn": true, "authMethod": "api_key"}"#)
                == GuideSignIn.Status(signedIn: true, account: GuideAccount(kind: .key)))
        #expect(GuideSignIn.read(#"{"loggedIn": false}"#) == GuideSignIn.Status(signedIn: false, account: nil))
        #expect(GuideSignIn.read("Not logged in") == nil)
        #expect(GuideSignIn.read("") == nil)
    }

    @Test func aPlansNameIsANameAndNeverFreeText() {
        #expect(GuideAccount.planName("max") == "max")
        #expect(GuideAccount.planName("Team Premium") == "Team Premium")
        #expect(GuideAccount.planName("a plan with a sentence in it, and more") == nil)
        #expect(GuideAccount.planName("owner@example.com") == nil)
        #expect(GuideAccount.planName(nil) == nil)
    }

    @Test func theStatusIsAskedWithTheSessionsSmallEnvironment() async {
        let status = await GuideSignIn.status(of: URL(fileURLWithPath: "/nowhere/claude"), home: "/Users/owner", user: "example") { program, arguments, environment in
            #expect(program.path == "/nowhere/claude")
            #expect(arguments == ["auth", "status", "--json"])
            #expect(environment == GuideCommand.environment(home: "/Users/owner", user: "example"))
            return #"{"loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "pro"}"#
        }
        #expect(status?.account == GuideAccount(kind: .plan, plan: "pro"))
    }
}
#endif
