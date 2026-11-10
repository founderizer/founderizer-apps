import CryptoKit
import Foundation

/// Founderizer updating **itself**, the way a Mac app updates (the owner's requirement 10).
///
/// The fleet already updates itself from our signed release channel (PRODUCT.md 4.3, `Releases.swift`). The app
/// that drives the fleet had no delivery at all: no download, no check, no way to receive a fix. This is that way,
/// and it is deliberately the *same* way.
///
/// **Why not Sparkle.** Sparkle is what a Mac user's muscle memory expects and it is a good framework, but it
/// brings a second Ed25519 key, made on a different machine, kept in a different place, with its own appcast
/// format and its own trust root. This product sells one promise — that we hold nothing of the customer's and that
/// what we do send them can be checked — and one key the customer can read on one page is worth more than a
/// framework. Sparkle also names a fleet to a feed only by query parameters on the appcast URL. So the app checks a
/// release the way the hub checks one: our release key, a line format that no other message of ours can be read as,
/// and the signature deciding.
///
/// **The signature decides, never a URL and never a version string.** A manifest that does not verify against the
/// release key is not read, not recorded and not offered. This build carries those keys (`shippedKeys`), the lines
/// of the fleet repository's `release-key.pub`, which the website serves at `/.well-known/founderizer-keys`, and the
/// early key of its `early-key.pub` (`earlyKeys`), which it trusts only while the fleet it drives takes releases
/// early (PRODUCT.md 4.3, "Who signs a release, and the two tracks"). A build that carries none refuses every
/// manifest and the screen says so, which is the safe state and not a gap: an app that cannot check an update takes
/// none.
///
/// **Only our side can refuse, never the Mac.** Founderizer has no subscription since 10 November 2026. Today's
/// channel still answers `401` or `402` to a fleet whose hub holds no token of the old subscription (PRODUCT.md 4.2),
/// and this app says that plainly, as what the channel answered. The open channel answers every fleet. Nothing here
/// refuses to work, nothing here expires, and the app that a person already has stays exactly as useful as it was.
public enum AppUpdate {
    /// Our channel, which is the hub's channel too. The hub's own `channel` overrides it when they differ, so a
    /// fleet pointed at another host needs no change here.
    public static let defaultChannel = "https://founderizer.com"

    /// Where the channel answers with the newest Mac build.
    public static let path = "releases/app"

    /// The fleet this Mac drives, sent because today's channel answers by fleet. It is the sixteen hex characters of
    /// PRODUCT.md 4.2 and says nothing about its owner. It is a header and never a query parameter. It goes when the
    /// open channel, which needs no fleet, is the only one.
    public static let fleetHeader = "Founderizer-Fleet"

    /// The release public keys of this build: the lines of `release-key.pub` in the fleet repository, the keys that
    /// sign a build for every Mac. Every key of the set is trusted, so a key is replaced the way the hub replaces one
    /// (PRODUCT.md 4.3, "How a signing key is replaced").
    ///
    /// No private half is on any server: the approve key is in the Secure Enclave of the owner's Mac and signs only
    /// after the owner's Touch ID, and the spare is in the owner's own password manager. The website's own key signed
    /// every build up to 0.1.105, which brought these two, and is no longer here.
    public static let shippedKeys = """
        8Gc80zgZcWqA7nX3+lChW09v2cOSi0lfjf4OzFiY2Ao=
        pQ2RwJ1nL5KXI7dv6Pt71GHMqk61hMA0NQmPUwlSFiY=
        """

    /// The early keys: the lines of `early-key.pub`, which sign each build as it is published. This app trusts them only
    /// while the fleet it drives takes releases early (`ReleaseState.early`): the owner's own fleet and Macs, which take
    /// each build before any customer does.
    public static let earlyKeys = "VxNkV9MNGrcPp62dGE9/mQjXsfgq7WAfWfnNzWSGZe4="

    /// Whether this build can check a manifest at all. A build with no key offers nothing — which is the same
    /// answer the hub gives about a fleet with no key, so the screen says it once.
    public static var carriesKey: Bool { !keys(shippedKeys).isEmpty }

    /// The keys one read of the channel checks with: the shipped ones, and the early ones too for a Mac whose fleet
    /// takes releases early.
    public static func trusted(early: Bool) -> [Data] { keys(shippedKeys) + (early ? keys(earlyKeys) : []) }

    /// The 32-byte keys of one key file's text, as the hub's `releases.parse_keys` reads it: lines that start with `#`
    /// are for the reader, at most four keys, and one line that is not a 32-byte key makes the whole text carry none,
    /// because a key file that is half read is a mistake. So the owner pastes the same lines into both places and
    /// neither can drift into a different format.
    public static func keys(_ text: String?) -> [Data] {
        guard let text else { return [] }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard (1...4).contains(lines.count) else { return [] }
        var found: [Data] = []
        for line in lines {
            guard let key = Data(base64Encoded: line), key.count == 32 else { return [] }
            found.append(key)
        }
        return found
    }
}

// ---------------------------------------------------------------- the manifest

/// What the channel says the newest Mac build is (`GET /releases/app`), after its signature was checked.
///
/// Every field is checked before the signature is computed over it, because the signed text is built from these
/// bytes: a field with a newline in it could otherwise be split into two fields on the way. So nothing here is
/// read loosely, exactly as `releases.read_manifest` reads nothing loosely.
public struct AppManifest: Equatable, Sendable {
    /// What the owner reads: `CFBundleShortVersionString` of the build, "2026.11.1".
    public let version: String
    /// What the comparison uses: `CFBundleVersion`, which only ever grows.
    public let build: Int
    /// The zip of the application bundle, on our own host over HTTPS.
    public let url: String
    /// The SHA-256 of that zip, lower-case hex. The bytes are checked against it before anything is unpacked.
    public let sha256: String
    /// Its size in bytes, checked before and after the download.
    public let size: Int
    /// The oldest macOS this build runs on, "15.0", or nil when it does not say.
    public let minimumSystem: String?
    /// The release notes page, on our own host over HTTPS, or nil.
    public let notes: String?
    /// We stopped this build. A held build is never offered, and the hold is inside the signed bytes so it cannot
    /// be stripped on the way.
    public let hold: Bool
    /// Base64 of the 64 raw Ed25519 bytes over `signedText`.
    public let signature: String

    public init(version: String, build: Int, url: String, sha256: String, size: Int,
                minimumSystem: String?, notes: String?, hold: Bool, signature: String) {
        self.version = version
        self.build = build
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.minimumSystem = minimumSystem
        self.notes = notes
        self.hold = hold
        self.signature = signature
    }

    /// The notes page, when it is one of our own addresses over HTTPS. A manifest comes from the network, so the
    /// app opens no link of another host (the rule `ReleaseRow.notesLink` already follows).
    public func notesLink(channel: String) -> URL? {
        guard let notes, let link = URL(string: notes), AppManifest.isOurs(link, channel: channel) else { return nil }
        return link
    }

    /// An address of ours: HTTPS, the channel's own host, and no credentials in it.
    static func isOurs(_ link: URL, channel: String) -> Bool {
        guard link.scheme == "https", let host = link.host?.lowercased(),
              let site = URL(string: channel)?.host?.lowercased(), host == site,
              link.user == nil, link.password == nil else { return false }
        return true
    }
}

/// A manifest this app will not act on, with the one line it says to the owner.
public struct AppUpdateUntrusted: LocalizedError, Equatable, Sendable {
    public let says: String
    public init(_ says: String) { self.says = says }
    public var errorDescription: String? { says }
}

extension AppUpdate {
    /// What a Mac build's signature covers. One line for each field, in this order, then a closing newline — the
    /// same discipline as `releases.signed_text` (PRODUCT.md 4.3, what P6 settled), so a signer in any language
    /// produces the same bytes and no field can be dropped on the way.
    ///
    /// The first line is `founderizer-app-1` and not `founderizer-release-1`: a fleet release and a Mac build are
    /// different messages signed by the same key, and neither can ever be replayed as the other. A later version
    /// numbers itself here and is refused by this one instead of guessed at.
    public static let signedPrefix = "founderizer-app-1"

    /// The exact bytes a Mac build's signature covers.
    public static func signedText(_ manifest: AppManifest) -> Data {
        let lines = [signedPrefix,
                     manifest.version,
                     String(manifest.build),
                     manifest.url,
                     manifest.sha256,
                     String(manifest.size),
                     manifest.minimumSystem ?? "",
                     manifest.notes ?? "",
                     manifest.hold ? "true" : "false"]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// The manifest of the channel's answer, field by field, before anything is done with it.
    ///
    /// This runs **before** the signature check, so it trusts not one character of what it reads. A field that
    /// does not match its shape ends the read, and so does a field that could change the signed text by carrying a
    /// newline — which is why each shape forbids one.
    public static func readManifest(_ data: Data, channel: String) throws -> AppManifest {
        guard data.count <= 64 * 1024,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppUpdateUntrusted("The channel did not answer with a build this app could read.")
        }
        guard let version = raw["version"] as? String,
              version.range(of: "^[A-Za-z0-9][A-Za-z0-9 ._+-]{0,40}$", options: .regularExpression) != nil else {
            throw AppUpdateUntrusted("The channel's answer has no version name.")
        }
        guard let build = whole(raw["build"]), (1...2_000_000_000).contains(build) else {
            throw AppUpdateUntrusted("The channel's answer has no build number.")
        }
        guard let address = raw["url"] as? String, address.utf8.count <= 400, let url = URL(string: address),
              AppManifest.isOurs(url, channel: channel), url.pathExtension.lowercased() == "zip" else {
            throw AppUpdateUntrusted("The channel's answer points the download somewhere that is not ours.")
        }
        guard let sha256 = raw["sha256"] as? String,
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw AppUpdateUntrusted("The channel's answer carries no checksum for the download.")
        }
        guard let size = whole(raw["size"]), (1...maximumDownload).contains(size) else {
            throw AppUpdateUntrusted("The channel's answer gives the download no believable size.")
        }
        let minimum = raw["minimum"] as? String
        if let minimum, !minimum.isEmpty,
           minimum.range(of: "^[0-9]{1,3}(\\.[0-9]{1,3}){0,2}$", options: .regularExpression) == nil {
            throw AppUpdateUntrusted("The channel's answer names a macOS version this app cannot read.")
        }
        let notes = raw["notes"] as? String
        if let notes, !notes.isEmpty,
           !(URL(string: notes).map { AppManifest.isOurs($0, channel: channel) } ?? false) {
            throw AppUpdateUntrusted("The channel's answer points its notes somewhere that is not ours.")
        }
        let hold = raw["hold"] ?? false
        guard let held = hold as? Bool else {
            throw AppUpdateUntrusted("The channel's answer does not say whether this build is held.")
        }
        guard let signature = raw["signature"] as? String, (1...200).contains(signature.utf8.count) else {
            throw AppUpdateUntrusted("The channel's answer carries no signature.")
        }
        return AppManifest(version: version, build: build, url: address, sha256: sha256, size: size,
                           minimumSystem: (minimum?.isEmpty ?? true) ? nil : minimum,
                           notes: (notes?.isEmpty ?? true) ? nil : notes, hold: held, signature: signature)
    }

    /// The manifest this app may act on, or `AppUpdateUntrusted`. Nothing else here reads an unchecked manifest.
    public static func check(_ data: Data, keys: [Data], channel: String) throws -> AppManifest {
        let manifest = try readManifest(data, channel: channel)
        guard !keys.isEmpty else {
            throw AppUpdateUntrusted("This build of Founderizer carries no release key, so it refuses every "
                                     + "update. That is the safe state: an app that cannot check an update takes none.")
        }
        guard let signature = Data(base64Encoded: manifest.signature), signature.count == 64 else {
            throw AppUpdateUntrusted("The channel's signature is not a signature.")
        }
        let text = signedText(manifest)
        guard keys.contains(where: { key in
            (try? Curve25519.Signing.PublicKey(rawRepresentation: key))?.isValidSignature(signature, for: text) == true
        }) else {
            throw AppUpdateUntrusted("This build is not signed by the release key Founderizer ships with. "
                                     + "Nothing was downloaded.")
        }
        return manifest
    }

    /// 600 MB. The app is a tenth of that; this is the line past which an answer is not believed at all.
    static let maximumDownload = 600 * 1024 * 1024

    /// A JSON whole number, and nothing that merely looks like one. A string is refused: the signed text renders
    /// the number itself, and two renderings of one value would be two different messages.
    private static func whole(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFNumberIsFloatType(number) == false else { return nil }
        return number.intValue
    }
}

// ---------------------------------------------------------------- this app, and what the channel offers it

/// The build of Founderizer that is running.
public struct AppVersion: Equatable, Sendable, Comparable {
    /// `CFBundleShortVersionString`: what the owner reads.
    public let name: String
    /// `CFBundleVersion`: what decides which build is newer.
    public let build: Int

    public init(name: String, build: Int) {
        self.name = name
        self.build = build
    }

    public static func < (one: AppVersion, other: AppVersion) -> Bool { one.build < other.build }

    /// This app's own version, or nil when the bundle does not say — in which case nothing is offered, because an
    /// app that cannot tell which build it is cannot tell whether another one is newer.
    public static var running: AppVersion? {
        guard let info = Bundle.main.infoDictionary,
              let name = info["CFBundleShortVersionString"] as? String,
              let build = Int((info["CFBundleVersion"] as? String) ?? "") else { return nil }
        return AppVersion(name: name, build: build)
    }

    public var line: String { "\(name) (build \(build))" }
}

/// **The Mac build that waited when the app last quit** (review B, round 3, 30 October 2026): kept with the fleet's
/// reading, so the sidebar's Update row draws in the next launch's first frame, where it came after the launch's reads
/// and its read of our channel. Only its version: it draws the row and nothing else, and the launch's own read of the
/// channel replaces it.
public struct WaitingBuild: Codable, Equatable, Sendable {
    public let version: String
    public let build: Int

    public init(_ manifest: AppManifest) {
        version = manifest.version
        build = manifest.build
    }

    /// It still waits for this Mac only while it is newer than the build that runs: an update that was put in place
    /// meanwhile never shows the row. A build that does not say which one it is waits for nothing.
    public func waits(over running: AppVersion?) -> Bool { running.map { $0.build < build } ?? false }

    /// The build kept in `data`, or nil: a launch that kept none (`null`), or a file that is no build.
    public static func kept(_ data: Data) -> WaitingBuild? {
        (try? JSONDecoder().decode(WaitingBuild?.self, from: data)) ?? nil
    }
}

/// What one read of the channel came to: the line the owner reads, and the build to offer when there is one.
public struct AppUpdateReading: Equatable, Sendable {
    /// The HTTP status, or 0 when the channel was not reached at all.
    public let status: Int
    /// One line, always, in the owner's own words.
    public let says: String
    /// The build the channel offers, when its signature verified. Present even when it is not offered — a held
    /// build and an up-to-date build both have a manifest and neither is installed.
    public let manifest: AppManifest?
    /// This build can be installed now: checked, newer than the one running, not held, and this Mac is new enough.
    public let offered: Bool
    /// Our channel refused this fleet (`401` or `402`). Nothing on the Mac stopped.
    public let refused: Bool
    /// This Mac runs the newest build the channel offers.
    public let current: Bool
    /// The channel did not answer, or answered with a server error (as while our site deploys), so this read knows
    /// nothing new: the last state known stands.
    public let unreachable: Bool

    public init(status: Int, says: String, manifest: AppManifest? = nil, offered: Bool = false,
                refused: Bool = false, current: Bool = false, unreachable: Bool = false) {
        self.status = status
        self.says = says
        self.manifest = manifest
        self.offered = offered
        self.refused = refused
        self.current = current
        self.unreachable = unreachable
    }
}

/// One read of the channel for the newest Mac build.
///
/// It reaches the network and decides nothing else: the download, the checks and the replacement are
/// `AppUpdateInstaller`'s, and they run only on a manifest that came back from here as `offered`.
public struct AppUpdateChannel: Sendable {
    /// A read of one address with its headers, answering the status and the body. Injected so that every path
    /// through this file is proved without a network.
    public typealias Fetch = @Sendable (URL, [String: String]) async throws -> (Int, Data)

    public let channel: String
    public let fleet: String?
    /// The fleet this Mac drives takes releases early, so this read asks for the early track and trusts its keys too.
    public let early: Bool
    private let keys: [Data]
    private let fetch: Fetch

    /// - Parameters:
    ///   - channel: our channel, or the one this fleet's own hub names.
    ///   - fleet: the sixteen hex characters of PRODUCT.md 4.2, when this Mac knows them. Today's channel answers
    ///     by it. A Mac with no fleet yet sends none.
    ///   - early: the fleet takes releases early (`ReleaseState.early`), as the owner's own fleet does.
    ///   - keys: the release keys this read checks with: `AppUpdate.trusted(early:)` unless a test names its own. With
    ///     none, every manifest is refused with one line.
    public init(channel: String = AppUpdate.defaultChannel, fleet: String? = nil, early: Bool = false,
                keys: [Data]? = nil, fetch: Fetch? = nil) {
        self.channel = channel
        self.fleet = (fleet.map { FleetID.isValid($0) } ?? false) ? fleet : nil
        self.early = early
        self.keys = keys ?? AppUpdate.trusted(early: early)
        self.fetch = fetch ?? AppUpdateChannel.network
    }

    /// Ask the channel what the newest Mac build is, and say what it means for this Mac.
    public func read(installed: AppVersion?,
                     system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) async -> AppUpdateReading {
        guard let site = URL(string: channel), site.scheme == "https", site.host != nil else {
            return AppUpdateReading(status: 0, says: "This fleet names a release channel that is not an HTTPS "
                                    + "address, so Founderizer asked nothing.")
        }
        guard !keys.isEmpty else {
            return AppUpdateReading(status: 0, says: "This build of Founderizer carries no release key, so it "
                                    + "refuses every update. That is the safe state: an app that cannot check an "
                                    + "update takes none.")
        }
        var headers = ["Accept": "application/json"]
        if let fleet { headers[AppUpdate.fleetHeader] = fleet }
        let answer: (status: Int, body: Data)
        let path = site.appendingPathComponent(AppUpdate.path)
        let address = early ? URL(string: path.absoluteString + "?track=early") ?? path : path
        do { answer = try await fetch(address, headers) } catch {
            // The page's button is Check for updates (24 October 2026); it was a refresh mark, which is what
            // this line used to point at.
            return AppUpdateReading(status: 0, says: "Founderizer could not reach our channel. Nothing changed on "
                                    + "this Mac, and it asks again by itself.", unreachable: true)
        }
        guard answer.status == 200 else { return refusal(answer.status) }
        let manifest: AppManifest
        do { manifest = try AppUpdate.check(answer.body, keys: keys, channel: channel) }
        catch let refused as AppUpdateUntrusted { return AppUpdateReading(status: answer.status, says: refused.says) }
        catch { return AppUpdateReading(status: answer.status, says: "The channel answered something this app could not read.") }
        return reading(manifest, status: answer.status, installed: installed, system: system)
    }

    /// What a checked manifest means for the Mac that is running.
    func reading(_ manifest: AppManifest, status: Int, installed: AppVersion?,
                 system: OperatingSystemVersion) -> AppUpdateReading {
        if manifest.hold {
            return AppUpdateReading(status: status,
                                    says: "Founderizer \(manifest.version) is held by us. No Mac takes a held build.",
                                    manifest: manifest)
        }
        guard let installed else {
            return AppUpdateReading(status: status,
                                    says: "Founderizer cannot tell which build it is, so it offers none. Download "
                                    + "the app again from our download page.", manifest: manifest)
        }
        guard manifest.build > installed.build else {
            return AppUpdateReading(status: status,
                                    says: "Founderizer \(installed.name) is the newest build. Nothing to install.",
                                    manifest: manifest, current: true)
        }
        if let needed = manifest.minimumSystem, !AppUpdateChannel.meets(needed, system: system) {
            return AppUpdateReading(status: status,
                                    says: "Founderizer \(manifest.version) needs macOS \(needed), and this Mac "
                                    + "runs \(AppUpdateChannel.systemLine(system)). Update macOS first.",
                                    manifest: manifest)
        }
        return AppUpdateReading(status: status,
                                says: "Founderizer \(manifest.version) is ready to install. "
                                + "This Mac runs \(installed.name).", manifest: manifest, offered: true)
    }

    /// What our side refusing means, in the owner's own words. A refusal of our channel is not a broken app and must
    /// never read as one: what stopped is ours, and the fleet keeps running.
    private func refusal(_ status: Int) -> AppUpdateReading {
        switch status {
        case 401, 402:
            guard fleet != nil else {
                // Not a lapse: this Mac has not been told which fleet it drives, so our side has nothing to look
                // up. A Mac that has just downloaded the app is in exactly this state, and has nothing to update.
                return AppUpdateReading(status: status,
                                        says: "Founderizer does not know which fleet this Mac drives yet, so our "
                                        + "channel has nothing to answer about. Link your fleet, or take the "
                                        + "newest build from our download page.")
            }
            // What the channel answered, in a few plain words (T-35, fix round 2), and no word of a subscription:
            // Founderizer has none. Only today's channel answers this, to a fleet whose hub holds no token.
            return AppUpdateReading(status: status, says: "Our channel refused this fleet (\(status)). Nothing "
                                    + "changed on this Mac.", refused: true)
        case 404:
            return AppUpdateReading(status: status, says: "No build of Founderizer is published yet.")
        case 503:
            return AppUpdateReading(status: status, says: "Our channel could not answer with a build it had "
                                    + "checked itself, so it sent none. Nothing was downloaded.", unreachable: true)
        case 500...599:
            return AppUpdateReading(status: status, says: "Our channel had an error (\(status)). Nothing changed on "
                                    + "this Mac, and it asks again by itself.", unreachable: true)
        default:
            return AppUpdateReading(status: status, says: "Our channel refused this Mac (\(status)). Nothing "
                                    + "changed here.")
        }
    }

    /// Whether this Mac is at least `needed` ("15.0", "15.4.1").
    static func meets(_ needed: String, system: OperatingSystemVersion) -> Bool {
        let wanted = needed.split(separator: ".").map { Int($0) ?? 0 }
        let here = [system.majorVersion, system.minorVersion, system.patchVersion]
        for (want, have) in zip(wanted, here) {
            if have != want { return have > want }
        }
        return true
    }

    static func systemLine(_ system: OperatingSystemVersion) -> String {
        system.patchVersion == 0 ? "\(system.majorVersion).\(system.minorVersion)"
            : "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
    }

    /// The real read. Nothing of the owner's is sent: no email, no address, no name, no token — only the fleet id,
    /// and only when there is one.
    private static let network: Fetch = { url, headers in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, answer) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = answer as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http.statusCode, data)
    }
}

// ---------------------------------------------------------------- the update nobody presses

/// When Founderizer updates itself without a press (the owner, 22 October 2026: "do they get the latest updates,
/// improvements and bug fixes automatically? it must be like that!").
///
/// It asks the channel when it starts and every hour after, sooner after a read that failed, and it puts a new build in
/// place only while the owner is away from the app, because the restart that follows would take away what he was
/// typing. One switch decides it, and it is the fleet's own Automatic updates: the fleet and the Mac that drives it
/// take a release the same way. A build that is not a Developer ID build is never replaced, so a development build made
/// on this Mac is never swapped for a published one under the person working on it.
public enum AppUpdatePolicy {
    /// Between two reads of the channel, so that a release reaches his Macs the same morning (the owner, 28 October
    /// 2026: "why didn't it update automatically to the next version if it's available?"). It was four hours.
    public static let every: TimeInterval = 3600
    /// After one, two and three reads in a row that failed, the next one comes this much sooner; then `every` again.
    /// A release makes our site restart, and a read in those minutes fails.
    public static let retries: [TimeInterval] = [60, 300, 900]
    /// How long reads may fail before the Updates page says so. A failure shorter than this is not news.
    public static let long: TimeInterval = 24 * 3600
    /// How long the app is in the background before it restarts itself onto a new build.
    public static let away: TimeInterval = 120

    /// Whether to read the channel now: at the first chance after the app starts, then once in each `every`, and
    /// after `failures` reads in a row that failed, once each of `retries` has passed.
    public static func shouldAsk(lastAsked: Date?, failures: Int = 0, now: Date) -> Bool {
        guard let lastAsked else { return true }
        let wait = (1...retries.count).contains(failures) ? retries[failures - 1] : every
        return now.timeIntervalSince(lastAsked) >= wait || now < lastAsked
    }

    /// Whether to install the offered build now: the switch is on, this is a published build, the owner has been
    /// away from the app for `away`, and no request of his is on its way to the hub.
    public static func shouldInstall(automatic: Bool, published: Bool, offered: Bool, awaySince: Date?, busy: Bool,
                                     now: Date) -> Bool {
        guard automatic, published, offered, !busy, let awaySince else { return false }
        return now.timeIntervalSince(awaySince) >= away
    }
}

/// **The words of the "Founderizer for Mac" row** (the Updates page), as few as the facts allow (the owner, 28 October
/// 2026: "instead of showing this, it should say 'Update available'. Also build number is not needed"). A read that did
/// not reach the channel is not news: the row keeps the last state it knew, and says that reads fail only once they
/// have failed for `AppUpdatePolicy.long`.
public enum AppUpdateWords {
    /// What the row says about the newest build: Update available, Up to date, or why neither, in the channel's words.
    /// With no reading at all yet, nothing: the version at the row's right is all there is to say.
    public static func state(_ reading: AppUpdateReading?) -> String? {
        guard let reading else { return nil }
        if reading.offered, let manifest = reading.manifest { return "Update available: \(manifest.version)" }
        if reading.current { return "Up to date" }
        return reading.says
    }

    /// The version at the row's right: the name, and no build number.
    public static func version(_ running: AppVersion?) -> String { running?.name ?? "Unknown build" }

    /// The row's warning when reads have failed for long, or nil.
    public static func failing(since: Date?, now: Date) -> String? {
        guard let since, now.timeIntervalSince(since) >= AppUpdatePolicy.long else { return nil }
        return "Our channel has not answered since \(since.formatted(date: .abbreviated, time: .omitted))."
    }
}
