import CryptoKit
import Foundation
import Testing
@testable import FleetCore

/// Founderizer updating itself (the owner's requirement 10, on the channel of PRODUCT.md 4.2 and 4.3).
///
/// Every one of these makes its own Ed25519 pair and proves the whole path against it, so the key this build
/// ships (`AppUpdate.shippedKey`) is checked in one test of its own and decides nothing else here.
struct AppUpdateTests {
    private static let channel = "https://founderizer.com"

    /// A build the channel could answer with, and the JSON it would answer with, signed by a key of this test's.
    private struct Build {
        var version = "2026.11.1"
        var build = 42
        var url = "https://founderizer.com/downloads/Founderizer-2026.11.1.zip"
        var sha256 = String(repeating: "a", count: 64)
        var size = 48_000_000
        var minimum: String? = "15.0"
        var notes: String? = "https://founderizer.com/releases/2026.11.1"
        var hold = false

        var manifest: AppManifest {
            AppManifest(version: version, build: build, url: url, sha256: sha256, size: size,
                        minimumSystem: minimum, notes: notes, hold: hold, signature: "")
        }

        /// The answer of the channel: the fields, and the signature over exactly the bytes of `signedText`.
        /// `changing` is what a channel on the way would alter after the signing, which is the thing to refuse.
        func json(signedBy key: Curve25519.Signing.PrivateKey, changing: [String: Any] = [:],
                  signature override: String? = nil) throws -> Data {
            let signed = try key.signature(for: AppUpdate.signedText(manifest)).base64EncodedString()
            var body: [String: Any] = ["version": version, "build": build, "url": url, "sha256": sha256,
                                       "size": size, "hold": hold, "signature": override ?? signed]
            if let minimum { body["minimum"] = minimum }
            if let notes { body["notes"] = notes }
            for (name, value) in changing { body[name] = value }
            return try JSONSerialization.data(withJSONObject: body)
        }
    }

    private func pair() -> (key: Curve25519.Signing.PrivateKey, publicKey: Data) {
        let key = Curve25519.Signing.PrivateKey()
        return (key, key.publicKey.rawRepresentation)
    }

    // ------------------------------------------------------------ the build kept for the next launch's Update row

    /// **A build kept from the last launch shows the Update row only while it is newer than the build that runs** (review
    /// B, round 3 of 30 October 2026): an update that was put in place meanwhile must never show the row.
    @Test func aKeptWaitingBuildWaitsOnlyOverAnOlderBuild() {
        let kept = WaitingBuild(Build().manifest)
        #expect(kept.version == "2026.11.1" && kept.build == 42)
        #expect(kept.waits(over: AppVersion(name: "2026.10.1", build: 12)))
        #expect(!kept.waits(over: AppVersion(name: "2026.11.1", build: 42)))
        #expect(!kept.waits(over: AppVersion(name: "2026.12.1", build: 50)))
        // A build that does not say which one it is waits for nothing, as nothing is offered to it.
        #expect(!kept.waits(over: nil))
    }

    /// **It reads back from the file kept with the fleet's**, and a launch that kept none, or a file that is no build,
    /// gives none.
    @Test func aKeptWaitingBuildReadsBack() throws {
        let kept = WaitingBuild(Build().manifest)
        #expect(WaitingBuild.kept(try JSONEncoder().encode(Optional(kept))) == kept)
        #expect(WaitingBuild.kept(try JSONEncoder().encode(WaitingBuild?.none)) == nil)
        #expect(WaitingBuild.kept(Data("not json".utf8)) == nil)
    }

    /// **A channel read that fails takes the kept build away** (review B, round 5 of 30 October 2026), as a failed read
    /// takes the kept health and releases away: the Update row stood on the build kept from the last launch, while the
    /// Updates page that it opens draws only this launch's reading and showed no build.
    @Test func aKeptWaitingBuildGoesWhenAChannelReadFails() {
        var kept = KeptReading(WaitingBuild(Build().manifest))
        #expect(kept.reading?.waits(over: AppVersion(name: "2026.10.1", build: 12)) == true)
        kept.readFailed()
        #expect(kept.reading == nil)
        #expect(KeptReading<WaitingBuild>().reading == nil)
    }

    // ------------------------------------------------------------ the bytes the signature covers

    @Test func theSignedTextIsOneLineForEachFieldInOneOrder() {
        let build = Build()
        let text = String(decoding: AppUpdate.signedText(build.manifest), as: UTF8.self)
        #expect(text == """
        founderizer-app-1
        2026.11.1
        42
        https://founderizer.com/downloads/Founderizer-2026.11.1.zip
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        48000000
        15.0
        https://founderizer.com/releases/2026.11.1
        false

        """)
    }

    @Test func anAbsentFieldIsAnEmptyLineAndNotAMissingOne() {
        var build = Build()
        build.minimum = nil
        build.notes = nil
        let text = String(decoding: AppUpdate.signedText(build.manifest), as: UTF8.self)
        #expect(text.hasSuffix("\n48000000\n\n\nfalse\n"))
    }

    @Test func aMacBuildIsNotAFleetRelease() throws {
        // The same key signs both messages. The first line is what keeps one from ever being read as the other.
        let (key, published) = pair()
        let build = Build()
        let fleetBytes = Data(("founderizer-release-1\n" + build.version + "\n").utf8)
        let wrongSignature = try key.signature(for: fleetBytes).base64EncodedString()
        let raw = try build.json(signedBy: key, signature: wrongSignature)
        #expect(throws: AppUpdateUntrusted.self) {
            try AppUpdate.check(raw, keys: [published], channel: Self.channel)
        }
    }

    // ------------------------------------------------------------ the signature decides

    @Test func aSignedBuildIsRead() throws {
        let (key, published) = pair()
        let manifest = try AppUpdate.check(try Build().json(signedBy: key), keys: [published], channel: Self.channel)
        #expect(manifest.version == "2026.11.1")
        #expect(manifest.build == 42)
        #expect(manifest.hold == false)
        #expect(manifest.notesLink(channel: Self.channel)?.absoluteString
                == "https://founderizer.com/releases/2026.11.1")
    }

    @Test func withoutAKeyEveryBuildIsRefused() throws {
        let (key, _) = pair()
        let raw = try Build().json(signedBy: key)
        let refused = #expect(throws: AppUpdateUntrusted.self) {
            try AppUpdate.check(raw, keys: [], channel: Self.channel)
        }
        #expect(refused?.says.contains("no release key") == true)
    }

    @Test func thisBuildCarriesTheReleaseKeysItChecksWith() {
        // The lines of `release-key.pub` and `early-key.pub` in the fleet repository. A build that carried another
        // line, or none, would refuse every update we publish, so this test is the one that would catch a character
        // lost on the way. The early key is trusted only for a fleet that takes releases early.
        #expect(AppUpdate.keys(AppUpdate.shippedKeys).map { $0.base64EncodedString() } ==
                ["8Gc80zgZcWqA7nX3+lChW09v2cOSi0lfjf4OzFiY2Ao=", "pQ2RwJ1nL5KXI7dv6Pt71GHMqk61hMA0NQmPUwlSFiY="])
        #expect(AppUpdate.keys(AppUpdate.earlyKeys).map { $0.base64EncodedString() } ==
                ["VxNkV9MNGrcPp62dGE9/mQjXsfgq7WAfWfnNzWSGZe4="])
        #expect(AppUpdate.trusted(early: false).count == 2)
        #expect(AppUpdate.trusted(early: true).count == 3)
        #expect(AppUpdate.carriesKey)
    }

    @Test func anyKeyOfTheSetChecksABuild() throws {
        let (key, published) = pair()
        let (_, other) = pair()
        let manifest = try AppUpdate.check(try Build().json(signedBy: key), keys: [other, published], channel: Self.channel)
        #expect(manifest.build == 42)
    }

    @Test func anotherKeysSignatureIsRefused() throws {
        let (key, _) = pair()
        let (_, somebodyElse) = pair()
        #expect(throws: AppUpdateUntrusted.self) {
            try AppUpdate.check(try Build().json(signedBy: key), keys: [somebodyElse], channel: Self.channel)
        }
    }

    @Test func oneFieldChangedOnTheWayIsRefused() throws {
        let changes: [[String: Any]] = [["hold": true], ["build": 99], ["version": "2026.99.9"], ["size": 1024],
                                        ["sha256": String(repeating: "b", count: 64)],
                                        ["url": "https://founderizer.com/downloads/other.zip"],
                                        ["notes": "https://founderizer.com/releases/other"],
                                        ["minimum": "26.0"]]
        let (key, published) = pair()
        for change in changes {
            let raw = try Build().json(signedBy: key, changing: change)
            #expect(throws: AppUpdateUntrusted.self, "\(change.keys.first ?? "") changed on the way") {
                try AppUpdate.check(raw, keys: [published], channel: Self.channel)
            }
        }
    }

    @Test func aHeldBuildKeepsItsHoldThroughTheSignature() throws {
        // The hold is inside the signed bytes, so a held build is read as held and cannot be flipped on the way.
        let (key, published) = pair()
        var build = Build()
        build.hold = true
        let manifest = try AppUpdate.check(try build.json(signedBy: key), keys: [published], channel: Self.channel)
        #expect(manifest.hold)
    }

    // ------------------------------------------------------------ what is read before the signature is computed

    @Test func anAnswerThatIsNotTheShapeIsNotRead() throws {
        let changes: [[String: Any]] = [["url": "http://founderizer.com/a.zip"],
                                        ["url": "https://example.com/a.zip"],
                                        ["url": "https://user:pass@founderizer.com/a.zip"],
                                        ["url": "https://founderizer.com/a.dmg"],
                                        ["notes": "https://example.com/notes"],
                                        ["build": "42"], ["build": 0], ["size": 0], ["size": 900_000_000],
                                        ["sha256": "not hex"], ["version": ""], ["version": "2026\n11"],
                                        ["minimum": "twenty six"], ["hold": "false"], ["signature": ""]]
        let (key, published) = pair()
        for change in changes {
            let raw = try Build().json(signedBy: key, changing: change)
            #expect(throws: AppUpdateUntrusted.self, "\(change) is not the shape") {
                try AppUpdate.check(raw, keys: [published], channel: Self.channel)
            }
        }
    }

    @Test func anAnswerThatIsNotJSONIsNotRead() {
        #expect(throws: AppUpdateUntrusted.self) {
            try AppUpdate.readManifest(Data("<html>not our channel</html>".utf8), channel: Self.channel)
        }
    }

    @Test func theKeyFileFormatIsTheHubsOwn() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let other = Data(repeating: 8, count: 32).base64EncodedString()
        #expect(AppUpdate.keys("# a comment\n\n\(key)\n") == [Data(repeating: 7, count: 32)])
        #expect(AppUpdate.keys("\(key)\n\(other)") == [Data(repeating: 7, count: 32), Data(repeating: 8, count: 32)])
        #expect(AppUpdate.keys(Array(repeating: key, count: 5).joined(separator: "\n")).isEmpty)    // four at most
        #expect(AppUpdate.keys("\(key)\n" + Data(repeating: 7, count: 31).base64EncodedString()).isEmpty) // half read
        #expect(AppUpdate.keys("not base64 at all !!").isEmpty)
        #expect(AppUpdate.keys(nil).isEmpty)
    }

    @Test func aMacWhoseFleetTakesReleasesEarlyAsksTheEarlyTrack() async throws {
        let (key, published) = pair()
        let body = try Build().json(signedBy: key)
        final class Seen: @unchecked Sendable { var urls: [URL] = [] }
        let seen = Seen()
        for early in [false, true] {
            _ = await AppUpdateChannel(channel: Self.channel, early: early, keys: [published]) { url, _ in
                seen.urls.append(url)
                return (200, body)
            }.read(installed: AppVersion(name: "2026.10.1", build: 12), system: Self.sonoma)
        }
        #expect(seen.urls.map(\.absoluteString) == ["https://founderizer.com/releases/app",
                                                    "https://founderizer.com/releases/app?track=early"])
    }

    // ------------------------------------------------------------ what the channel's answer means for this Mac

    private func channel(_ status: Int, _ body: Data, fleet: String? = nil,
                         key: Data?, seen: @escaping @Sendable (URL, [String: String]) -> Void = { _, _ in })
    -> AppUpdateChannel {
        AppUpdateChannel(channel: Self.channel, fleet: fleet, keys: key.map { [$0] } ?? []) { url, headers in
            seen(url, headers)
            return (status, body)
        }
    }

    private static let sonoma = OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)

    @Test func aNewerBuildIsOffered() async throws {
        let (key, published) = pair()
        let reading = await channel(200, try Build().json(signedBy: key), key: published)
            .read(installed: AppVersion(name: "2026.10.1", build: 12), system: Self.sonoma)
        #expect(reading.offered)
        #expect(reading.manifest?.build == 42)
        #expect(reading.says.contains("2026.11.1"))
    }

    @Test func theSameBuildIsNotOffered() async throws {
        let (key, published) = pair()
        let reading = await channel(200, try Build().json(signedBy: key), key: published)
            .read(installed: AppVersion(name: "2026.11.1", build: 42), system: Self.sonoma)
        #expect(!reading.offered && reading.current && !reading.unreachable)
        #expect(reading.says.contains("newest build"))
    }

    @Test func anOlderMacIsToldWhatItNeedsAndNothingIsOffered() async throws {
        let (key, published) = pair()
        var build = Build()
        build.minimum = "26.0"
        let reading = await channel(200, try build.json(signedBy: key), key: published)
            .read(installed: AppVersion(name: "2026.10.1", build: 12), system: Self.sonoma)
        #expect(!reading.offered)
        #expect(reading.says.contains("needs macOS 26.0"))
        #expect(reading.says.contains("15.4"))
    }

    @Test func aHeldBuildIsNeverOffered() async throws {
        let (key, published) = pair()
        var build = Build()
        build.hold = true
        let reading = await channel(200, try build.json(signedBy: key), key: published)
            .read(installed: AppVersion(name: "2026.10.1", build: 12), system: Self.sonoma)
        #expect(!reading.offered)
        #expect(reading.says.contains("held"))
    }

    @Test func anAppThatCannotTellItsOwnBuildOffersNothing() async throws {
        let (key, published) = pair()
        let reading = await channel(200, try Build().json(signedBy: key), key: published)
            .read(installed: nil, system: Self.sonoma)
        #expect(!reading.offered)
        #expect(reading.says.contains("cannot tell which build it is"))
    }

    @Test func withoutAKeyTheChannelIsNotEvenAsked() async throws {
        let asked = Asked()
        let reading = await AppUpdateChannel(channel: Self.channel, keys: [],
                                             fetch: { url, _ in asked.note(url); return (200, Data()) })
            .read(installed: AppVersion(name: "1", build: 1), system: Self.sonoma)
        #expect(asked.count == 0)
        #expect(!reading.offered)
        #expect(reading.says.contains("no release key"))
    }

    /// What the channel answered, in a few plain words (T-35, fix round 2), and no word of a subscription: Founderizer
    /// has none. Only today's channel answers `401` or `402`, to a fleet whose hub holds no token.
    @Test func aRefusalOfOurChannelIsSaidAsWhatItAnswered() async throws {
        let (_, published) = pair()
        for status in [401, 402] {
            let reading = await channel(status, Data(), fleet: "0123456789abcdef", key: published)
                .read(installed: AppVersion(name: "2026.10.1", build: 12), system: Self.sonoma)
            #expect(reading.refused)
            #expect(!reading.offered)
            #expect(reading.says == "Our channel refused this fleet (\(status)). Nothing changed on this Mac.")
            #expect(reading.says.split(separator: " ").count <= 12)
            for word in ["subscription", "lapsed", "plan", "account", "pay"] { #expect(!reading.says.lowercased().contains(word)) }
        }
    }

    @Test func aMacWithNoFleetIsNotToldThatItsFleetWasRefused() async throws {
        // No fleet of this Mac was refused: it has not been linked to one, so our side has nothing to look up.
        let (_, published) = pair()
        let reading = await channel(402, Data(), key: published)
            .read(installed: AppVersion(name: "2026.10.1", build: 12), system: Self.sonoma)
        #expect(!reading.refused)
        #expect(!reading.offered)
        #expect(reading.says.contains("does not know which fleet"))
    }

    @Test func nothingPublishedAndOurOwnFailureEachSayTheirOwnLine() async throws {
        let (_, published) = pair()
        let nothing = await channel(404, Data(), key: published)
            .read(installed: AppVersion(name: "a", build: 1), system: Self.sonoma)
        #expect(nothing.says.contains("No build of Founderizer is published"))
        #expect(!nothing.refused)
        let ours = await channel(503, Data(), key: published)
            .read(installed: AppVersion(name: "a", build: 1), system: Self.sonoma)
        #expect(ours.says.contains("could not answer with a build it had checked"))
        #expect(!nothing.unreachable && ours.unreachable)
    }

    @Test func aChannelThatCannotBeReachedChangesNothing() async throws {
        let (_, published) = pair()
        let reading = await AppUpdateChannel(channel: Self.channel, keys: [published],
                                             fetch: { _, _ in throw URLError(.notConnectedToInternet) })
            .read(installed: AppVersion(name: "a", build: 1), system: Self.sonoma)
        #expect(reading.status == 0 && reading.unreachable)
        #expect(!reading.offered && !reading.current)
        #expect(reading.says.contains("could not reach"))
        // A server error, as while our site deploys, is a read that did not reach the channel too.
        for status in [500, 502, 504] {
            let failed = await channel(status, Data(), key: published)
                .read(installed: AppVersion(name: "a", build: 1), system: Self.sonoma)
            #expect(failed.status == status && failed.unreachable && !failed.offered)
        }
    }

    /// The row of "Founderizer for Mac" (the owner, 28 October 2026: "instead of showing this, it should say 'Update
    /// available'. Also build number is not needed"): a newer build is Update available with its version, this one is
    /// Up to date, the version has no build number, and reads that fail are said only after a day of them.
    @Test func theRowSaysUpdateAvailableOrUpToDateAndNoBuildNumber() async throws {
        let (key, published) = pair()
        let older = AppVersion(name: "2026.10.1", build: 12), newest = AppVersion(name: "2026.11.1", build: 42)
        let offered = await channel(200, try Build().json(signedBy: key), key: published)
            .read(installed: older, system: Self.sonoma)
        #expect(AppUpdateWords.state(offered) == "Update available: 2026.11.1")
        let current = await channel(200, try Build().json(signedBy: key), key: published)
            .read(installed: newest, system: Self.sonoma)
        #expect(AppUpdateWords.state(current) == "Up to date")
        // Never read yet: no line, and the version at the right by its name alone.
        #expect(AppUpdateWords.state(nil) == nil)
        #expect(AppUpdateWords.version(older) == "2026.10.1")
        // Anything else is the channel's own line (a held build here).
        var held = Build(); held.hold = true
        let holding = await channel(200, try held.json(signedBy: key), key: published)
            .read(installed: older, system: Self.sonoma)
        #expect(AppUpdateWords.state(holding)?.contains("held") == true)
        // A failure is not news before a day of them.
        let since = Date(timeIntervalSince1970: 1_792_660_000)
        #expect(AppUpdateWords.failing(since: nil, now: since) == nil)
        #expect(AppUpdateWords.failing(since: since, now: since.addingTimeInterval(23 * 3600)) == nil)
        #expect(AppUpdateWords.failing(since: since, now: since.addingTimeInterval(24 * 3600))?
            .hasPrefix("Our channel has not answered since") == true)
    }

    @Test func aChannelThatIsNotHTTPSIsNotAsked() async throws {
        let asked = Asked()
        let reading = await AppUpdateChannel(channel: "http://founderizer.com", keys: [Data(repeating: 1, count: 32)],
                                             fetch: { url, _ in asked.note(url); return (200, Data()) })
            .read(installed: AppVersion(name: "a", build: 1), system: Self.sonoma)
        #expect(asked.count == 0)
        #expect(reading.says.contains("not an HTTPS address"))
    }

    @Test func theFleetIdGoesInAHeaderAndNeverInTheAddress() async throws {
        let (key, published) = pair()
        let asked = Asked()
        _ = await channel(200, try Build().json(signedBy: key), fleet: "0123456789abcdef", key: published,
                          seen: { url, headers in asked.note(url, headers) })
            .read(installed: AppVersion(name: "a", build: 1), system: Self.sonoma)
        #expect(asked.last?.url.absoluteString == "https://founderizer.com/releases/app")
        #expect(asked.last?.url.query == nil)
        #expect(asked.last?.headers[AppUpdate.fleetHeader] == "0123456789abcdef")
    }

    @Test func aMacWithNoFleetSendsNoFleet() async throws {
        let (key, published) = pair()
        let asked = Asked()
        _ = await channel(200, try Build().json(signedBy: key), fleet: "not a fleet id", key: published,
                          seen: { url, headers in asked.note(url, headers) })
            .read(installed: AppVersion(name: "a", build: 1), system: Self.sonoma)
        #expect(asked.last?.headers[AppUpdate.fleetHeader] == nil)
    }

    @Test func thisMacIsComparedWithTheMacOSTheBuildNeeds() {
        let here = OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 1)
        #expect(AppUpdateChannel.meets("15", system: here))
        #expect(AppUpdateChannel.meets("15.4", system: here))
        #expect(AppUpdateChannel.meets("15.4.1", system: here))
        #expect(!AppUpdateChannel.meets("15.4.2", system: here))
        #expect(!AppUpdateChannel.meets("15.5", system: here))
        #expect(!AppUpdateChannel.meets("26.0", system: here))
        #expect(AppUpdateChannel.meets("14.9", system: here))
    }

    /// The update nobody presses: asked at the start and every hour, put in place only while the owner is away. After
    /// a read that failed (our site restarts with each release), the next ones come after 1, 5 and 15 minutes.
    @Test func theAppAsksAtItsStartThenEveryHourAndSoonAfterAFailedRead() {
        let start = Date(timeIntervalSince1970: 1_792_660_000)
        func asks(after minutes: Double, failures: Int = 0) -> Bool {
            AppUpdatePolicy.shouldAsk(lastAsked: start, failures: failures, now: start.addingTimeInterval(minutes * 60))
        }
        #expect(AppUpdatePolicy.shouldAsk(lastAsked: nil, now: start))
        #expect(!asks(after: 59) && asks(after: 60))
        #expect(!asks(after: 0.9, failures: 1) && asks(after: 1, failures: 1))
        #expect(!asks(after: 4, failures: 2) && asks(after: 5, failures: 2))
        #expect(!asks(after: 14, failures: 3) && asks(after: 15, failures: 3))
        #expect(!asks(after: 59, failures: 4) && asks(after: 60, failures: 4))     // then the hourly pace again
        #expect(asks(after: -1))                                                  // a clock set back
    }

    @Test func aNewBuildIsPutInPlaceOnlyWhileTheOwnerIsAway() {
        let now = Date(timeIntervalSince1970: 1_792_660_000)
        let away = now.addingTimeInterval(-AppUpdatePolicy.away)
        func install(automatic: Bool = true, published: Bool = true, offered: Bool = true, awaySince: Date? = away,
                     busy: Bool = false) -> Bool {
            AppUpdatePolicy.shouldInstall(automatic: automatic, published: published, offered: offered,
                                          awaySince: awaySince, busy: busy, now: now)
        }
        #expect(install())
        #expect(!install(awaySince: nil))                                   // he is using the app
        #expect(!install(awaySince: now.addingTimeInterval(-30)))           // he left it half a minute ago
        #expect(!install(automatic: false))                                 // the fleet's switch is off
        #expect(!install(published: false))                                 // a development build stays
        #expect(!install(offered: false))                                   // nothing newer, or it is held
        #expect(!install(busy: true))                                       // a request of his is on its way
    }

    /// What the injected read was asked, kept where a `@Sendable` closure may write it.
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(url: URL, headers: [String: String])] = []
        func note(_ url: URL, _ headers: [String: String] = [:]) {
            lock.lock(); defer { lock.unlock() }
            seen.append((url, headers))
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return seen.count }
        var last: (url: URL, headers: [String: String])? { lock.lock(); defer { lock.unlock() }; return seen.last }
    }
}
