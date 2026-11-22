import Foundation
#if os(macOS)
import MachO
import os
#endif

// ---------------------------------------------------------------- the switch

/// **Error reports** (the owner's "Yes, as drawn" of 16 November 2026, to the picture `P3-error-reports-switch.png`):
/// Settings › Help › Error reports › Help improve Founderizer (in General until his "Build A" of the same day). It is
/// off until the owner turns it on, and only that switch turns it on. While it is on, the crashes of this app that
/// MetricKit gives it go to our own site as codes and counts (`ErrorReport`): no text of a crash, no work, no name and
/// no key.
///
/// `GET /ui/error-reports?db=<generation>` (owner feature `error_reports`) answers `{"send", "db"}`: whether the switch
/// is on, for that generation (a missing or another generation is the hub's 409 `hub_changed`, as for every owner
/// read). `POST /ui/error-reports` sets it, an owner command as `POST /ui/releases/auto` is (`HubClient.errorReports`).
public struct ErrorReportsState: Decodable, Equatable, Sendable {
    public static let feature = "error_reports"
    /// The switch is on: the hub and this Mac send their reports.
    public let send: Bool
    /// The hub's generation that the answer is of.
    public let db: String

    public init(send: Bool, db: String) {
        self.send = send
        self.db = db
    }

    /// An answer of another generation is no answer of this one.
    public func validate(database: String) throws {
        guard db == database else { throw HubError.invalidResponse }
    }
}

/// **The owner's answer on the first run's page "Help improve Founderizer"** (the owner, 18 November 2026: "durng the
/// very first onboarding, one of the first steps should be asking if they wnat to share diagnosis data to improve the
/// product. then they can change the setting again under logs", and "Yes, build it" to the page's picture, with
/// Settings › Help as the place to change it). The page stands before any hub, so this Mac keeps the answer twice: the
/// card that carries the check mark (`chosen`), and the answer that waits for a hub (`waiting`). The first hub that
/// answers this Mac as its owner and offers the switch gets the waiting answer, as a press on Settings › Help › Help
/// improve Founderizer gives it (`POST /ui/error-reports`), and only its receipt ends the wait (`deliver`). Before that
/// nothing is sent anywhere: the switch is the hub's, and it is off until the hub takes an answer that turns it on.
/// **The wait is of one first run** (the review of 18 November 2026): it ends without a send (`forget`) when the first
/// run starts again on its welcome page, also at the next start of the app, and when the owner turns the switch in
/// Settings › Help, so that an answer of a first run that he left never reaches a fleet months later, and a retry never
/// undoes his newer press. Each of those fails closed: the switch stays as the hub has it.
public enum FirstRunReports {
    /// The card with the check mark: `send` or `none`. It stays after a hub took the answer.
    public static let choiceKey = "firstRunErrorReports"
    /// The answer that no hub took yet: `send` or `none`.
    public static let waitingKey = "firstRunErrorReportsWaiting"
    /// The time of the owner's last press on a card, in seconds since 1970: the start of the installs that a report may
    /// carry once a hub took his "Send" (`ErrorReportsDay.pressedOn`).
    static let pressedKey = "firstRunErrorReportsPressed"

    /// The card that the owner chose last on this Mac: true to send, false not to, nil before the first answer.
    public static func chosen(in defaults: UserDefaults = AppDefaults.store) -> Bool? { answer(defaults.string(forKey: choiceKey)) }

    /// The answer that waits for a hub, or nil when none waits.
    public static func waiting(in defaults: UserDefaults = AppDefaults.store) -> Bool? { answer(defaults.string(forKey: waitingKey)) }

    /// A press on a card of the page: the check mark, and the answer that the next hub gets. **A "no" is also the
    /// switch's last answer** (`ErrorReportsDay`): the wait of the answer ends at a hub's receipt, at Back to the welcome
    /// page and at a new start of the app, and the day of a hub that does not answer must not go on an older "on" then.
    public static func choose(_ send: Bool, at now: Date = Date(), in defaults: UserDefaults = AppDefaults.store) {
        defaults.set(word(send), forKey: choiceKey)
        defaults.set(word(send), forKey: waitingKey)
        defaults.set(now.timeIntervalSince1970, forKey: pressedKey)
        if !send { ErrorReportsDay.take(.off, now: now, in: defaults) }
    }

    /// The time of the owner's last press on a card of the page, or nil before the first one.
    public static func pressed(in defaults: UserDefaults = AppDefaults.store) -> Date? {
        (defaults.object(forKey: pressedKey) as? Double).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
    }

    /// **Gives the waiting answer to a hub**, with `send`, which makes the hub's call. True when the hub took it: the
    /// wait then ends, unless a press of the owner wrote another answer while the call ran. A hub that does not offer
    /// the switch (`offered`) gets nothing, and an answer that a call did not bring to the hub (no answer, a refusal)
    /// waits for the next call. It runs on the caller's own actor (`isolation`), the app's main actor.
    @discardableResult
    public static func deliver(offered: Bool, in defaults: UserDefaults = AppDefaults.store,
                               isolation: isolated (any Actor)? = #isolation,
                               send: (Bool) async throws -> Void) async -> Bool {
        guard offered, let answer = waiting(in: defaults) else { return false }
        do { try await send(answer) } catch { return false }
        if waiting(in: defaults) == answer { defaults.removeObject(forKey: waitingKey) }
        return true
    }

    /// The wait ends with no send. The check mark stays.
    public static func forget(in defaults: UserDefaults = AppDefaults.store) { defaults.removeObject(forKey: waitingKey) }

    private static func word(_ send: Bool) -> String { send ? "send" : "none" }

    private static func answer(_ word: String?) -> Bool? {
        switch word {
        case "send": true
        case "none": false
        default: nil
        }
    }
}

/// The hub's receipt of `POST /ui/error-reports`: the receipt of every owner command, and the switch as it is now
/// when the hub says it.
public struct ErrorReportsReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let replayed: Bool?
    public let send: Bool?
}

// ---------------------------------------------------------------- the report

/// **One report of this Mac's crashes to our own site**: `POST <channel>/api/errors` with `"from": "mac"`, the contract
/// of `feedback-diagnostics-plan.md` (Phase 3). The fleet's id, this app's version, the system's version and the
/// crashes, and nothing else: the site refuses (400) a report with any other key or any value outside its caps and
/// patterns, so every value is checked here before anything leaves, and one that does not pass is left out.
///
/// **No text of a crash is in it, and none is read**: no exception reason, no termination reason, no memory region
/// text and no name of a binary. A frame of this app's own executable is its binary's UUID and its offset; every other
/// frame is `"lib"`.
public struct ErrorReport: Encodable, Equatable, Sendable {
    /// The largest body the site takes.
    public static let maxBytes = 65_536
    public static let maxCrashes = 20
    public static let maxFrames = 32
    public static let maxCount = 1_000_000_000
    /// The highest offset into a binary's text segment: 2^40.
    public static let maxOffset = 1 << 40
    /// A crash's time, in whole seconds since 1970, as the contract takes it.
    public static let times: ClosedRange<Int> = 1_600_000_000...4_000_000_000
    public static let signals: ClosedRange<Int> = 0...64
    public static let types: ClosedRange<Int> = 0...1000
    /// **A code that a JSON number keeps exactly**: a larger one (a 64-bit code of a guard exception) goes as null, so
    /// that a site that reads numbers as doubles never refuses the whole report for it.
    public static let codes: ClosedRange<Int> = -((1 << 53) - 1)...((1 << 53) - 1)
    static let fleetPattern = #"\A[0-9a-f]{16}\z"#
    /// MAC_VERSION of the contract (founderizer-web, src/lib/errors.ts), from the first character to the last: "0.1.285
    /// (286)". A version of another form would make our site refuse each report, the day too, so it makes none.
    static let versionPattern = #"\A[0-9]{1,6}(\.[0-9]{1,6}){1,3} \([0-9]{1,9}\)\z"#
    /// SYSTEM of the contract: one word of letters and, when it has one, its version number ("macOS 26.6.2"). It is
    /// optional, so a system of another form is left out and the report goes.
    static let systemPattern = #"\A[A-Za-z]{1,16}( [0-9]{1,4}(\.[0-9]{1,4}){0,3})?\z"#
    static let uuidPattern = #"\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z"#

    /// The fleet's sixteen hex characters (`Entitlement.fleet`), as Report a problem names it.
    public let fleet: String
    /// Always "mac": the hub sends its own reports.
    public let from: String
    /// This app's version as `AppVersion.running` names it: "0.1.285 (286)" (`version(of:)`).
    public let version: String
    /// "macOS 26.6.2"; nil when it does not fit the contract.
    public let system: String?
    public let crashes: [Crash]
    /// **The Mac's day** (W17, `AppHealth`): in the day's report only, and nil in a report of crashes alone.
    public let app: AppHealth?

    /// The report, or nil when it cannot be sent: no fleet id or version of the contract's shape, or no crash that is
    /// one and no day (`app`). Identical crashes are one entry, and at most `maxCrashes` go: the ones seen last.
    public init?(fleet: String?, version: String?, system: String?, crashes: [Crash], app: AppHealth? = nil) {
        guard let fleet, Self.matches(fleet, Self.fleetPattern), let version, Self.matches(version, Self.versionPattern)
        else { return nil }
        let crashes = Self.merged(crashes.compactMap(\.checked))
        guard !crashes.isEmpty || app != nil else { return nil }
        self.fleet = fleet
        self.from = "mac"
        self.version = version
        self.system = system.flatMap { Self.matches($0, Self.systemPattern) ? $0 : nil }
        self.crashes = crashes
        self.app = app
    }

    private init(copy report: ErrorReport, app: AppHealth?) {
        fleet = report.fleet; from = report.from; version = report.version; system = report.system
        crashes = report.crashes
        self.app = app
    }

    /// **The same report without the day**: what goes again at once when our site refuses a report with it (the
    /// contract's "The health of a fleet"), also when no crash is in it.
    public var withoutApp: ErrorReport { ErrorReport(copy: self, app: nil) }

    /// The version of the build that runs, as the report names it.
    public static func version(of running: AppVersion?) -> String? {
        running.map { "\($0.name) (\($0.build))" }
    }

    /// The body that goes: the contract's keys only, in a fixed order.
    public func body() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maxBytes else { throw ErrorReportError.tooLarge }
        return data
    }

    private enum CodingKeys: String, CodingKey { case fleet, from, version, system, crashes, app }

    /// **An optional key of the report is left out, never `null`**: the site refuses a null key at the top, so a report
    /// with no system has no `system`, a day with no crash has no `crashes`, and a report of crashes has no `app`.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(fleet, forKey: .fleet)
        try values.encode(from, forKey: .from)
        try values.encode(version, forKey: .version)
        if let system { try values.encode(system, forKey: .system) }
        if !crashes.isEmpty { try values.encode(crashes, forKey: .crashes) }
        if let app { try values.encode(app, forKey: .app) }
    }

    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    /// A binary's UUID in the contract's form (lower case), or nil for anything else.
    static func uuid(_ value: String) -> String? {
        let lower = value.lowercased()
        return matches(lower, uuidPattern) ? lower : nil
    }

    // ------------------------------------------------------------ one crash

    /// One crash, or several identical ones: the contract's `crashes` entry.
    public struct Crash: Codable, Hashable, Sendable {
        /// The signal (`sys/signal.h`), the Mach exception's type and its code (`sys/exception_types.h`): numbers of the
        /// system, never words.
        public let signal: Int?
        public let type: Int?
        public let code: Int?
        /// The crashed thread, from the frame that ran down to the thread's start: at most `maxFrames`.
        public let frames: [Frame]
        public let count: Int
        /// The first and the last time it came, in whole seconds since 1970.
        public let first: Int
        public let last: Int

        public init(signal: Int?, type: Int?, code: Int?, frames: [Frame], count: Int = 1, first: Int, last: Int) {
            self.signal = signal; self.type = type; self.code = code
            self.frames = frames; self.count = count; self.first = first; self.last = last
        }

        /// The same crash: what decides that two entries are one.
        struct Signature: Hashable {
            let signal: Int?, type: Int?, code: Int?, frames: [Frame]
        }

        var signature: Signature { Signature(signal: signal, type: type, code: code, frames: frames) }

        /// This crash and an identical one, as one entry.
        func adding(_ other: Crash) -> Crash {
            Crash(signal: signal, type: type, code: code, frames: frames,
                  count: min(count + other.count, ErrorReport.maxCount), first: min(first, other.first),
                  last: max(last, other.last))
        }

        /// The entry when each of its values fits the contract, else nil: one value that does not would make the site
        /// refuse the whole report.
        public var checked: Crash? {
            guard signal.map({ ErrorReport.signals.contains($0) }) ?? true, type.map({ ErrorReport.types.contains($0) }) ?? true,
                  code.map({ ErrorReport.codes.contains($0) }) ?? true, frames.count <= ErrorReport.maxFrames,
                  frames.allSatisfy(\.isValid), (1...ErrorReport.maxCount).contains(count),
                  ErrorReport.times.contains(first), ErrorReport.times.contains(last), first <= last else { return nil }
            return self
        }

        private enum CodingKeys: String, CodingKey { case signal, type, code, frames, count, first, last }

        /// **Every key of an entry is there**: the site refuses an entry without one, so the three numbers go as `null`
        /// when the crash has none (a synthesized encoder would leave them out).
        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            for (number, key) in [(signal, CodingKeys.signal), (type, .type), (code, .code)] {
                if let number { try values.encode(number, forKey: key) } else { try values.encodeNil(forKey: key) }
            }
            try values.encode(frames, forKey: .frames)
            try values.encode(count, forKey: .count)
            try values.encode(first, forKey: .first)
            try values.encode(last, forKey: .last)
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            signal = try values.decodeIfPresent(Int.self, forKey: .signal)
            type = try values.decodeIfPresent(Int.self, forKey: .type)
            code = try values.decodeIfPresent(Int.self, forKey: .code)
            frames = try values.decode([Frame].self, forKey: .frames)
            count = try values.decode(Int.self, forKey: .count)
            first = try values.decode(Int.self, forKey: .first)
            last = try values.decode(Int.self, forKey: .last)
        }
    }

    /// One frame: this app's own executable as its binary's UUID and the offset into its text segment, every other
    /// binary as `"lib"` with offset 0.
    public struct Frame: Codable, Hashable, Sendable {
        public let image: String
        public let offset: Int

        public init(image: String, offset: Int) {
            self.image = image
            self.offset = offset
        }

        public static let lib = Frame(image: "lib", offset: 0)

        var isValid: Bool {
            image == "lib" ? offset == 0 : ErrorReport.uuid(image) == image && (0...ErrorReport.maxOffset).contains(offset)
        }
    }
}

/// Why a report did not go. No screen shows it.
public enum ErrorReportError: Error, Equatable, Sendable {
    /// The fleet's channel is not our own site over HTTPS (`OurSite`): nothing leaves.
    case badChannel
    /// The body would pass the site's limit.
    case tooLarge
    /// Our site answered with another status than 200.
    case refused(Int)
    /// No report could be made yet: the hub did not give the fleet's id and channel, or this build has no version.
    case unready

    /// **Whether the crashes of a report that did not go wait for the next start**: only when another send of the same
    /// report can go. Our site answered 429 (too often) or 5xx, or there was no answer (no connection, a time limit, a
    /// channel that is not ours, no report yet). Every other answer of the site says that it will never take that
    /// payload (400 for its shape, any other 4xx), and a report too large for it never goes: then nothing is kept.
    public static func keeps(_ error: Error) -> Bool {
        switch error {
        case ErrorReportError.refused(let status): status == 0 || status == 429 || (500...599).contains(status)
        case ErrorReportError.tooLarge: false
        default: true
        }
    }
}

// ---------------------------------------------------------------- from MetricKit's call stack tree

extension ErrorReport {
    /// **One crash, from the JSON of its MetricKit call stack tree** (`MXCallStackTree.jsonRepresentation()`) **and its
    /// numbers**: the signal, the exception's type and code, and the time of the payload that carried it.
    ///
    /// The frames are those of the thread that the crash is attributed to (`threadAttributed`), from its root frame
    /// (the one that ran) down through each frame's `subFrames`, at most `maxFrames`. A frame whose `binaryUUID` is one
    /// of `own`, this app's own executable (the build that runs, and those that ran before it on this Mac), is that UUID
    /// and its `offsetIntoBinaryTextSegment`; every other frame is `"lib"`. The tree's other keys are never read: not
    /// `binaryName`, not `address`, nothing else.
    ///
    /// nil only for a time outside the contract's: a clock that is that wrong gives no time worth sending.
    public static func crash(stackTree json: Data, signal: Int?, type: Int?, code: Int?, at time: Date,
                             own: Set<String>) -> Crash? {
        let seconds = time.timeIntervalSince1970
        guard seconds.isFinite, Double(times.lowerBound) <= seconds, seconds <= Double(times.upperBound) else { return nil }
        let when = Int(seconds)
        return Crash(signal: signal.flatMap { signals.contains($0) ? $0 : nil },
                     type: type.flatMap { types.contains($0) ? $0 : nil },
                     code: code.flatMap { codes.contains($0) ? $0 : nil },
                     frames: frames(of: json, own: Set(own.compactMap(uuid))), first: when, last: when)
    }

    /// The crashed thread's frames, in the order of the stack: depth first, each frame before its sub-frames.
    static func frames(of json: Data, own: Set<String>) -> [Frame] {
        guard let tree = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]],
              let crashed = stacks.first(where: { ($0["threadAttributed"] as? Bool) == true }),
              let roots = crashed["callStackRootFrames"] as? [[String: Any]] else { return [] }
        var frames: [Frame] = []
        var next = Array(roots.reversed())
        while frames.count < maxFrames, let node = next.popLast() {
            frames.append(frame(node, own: own))
            if let below = node["subFrames"] as? [[String: Any]] { next.append(contentsOf: below.reversed()) }
        }
        return frames
    }

    private static func frame(_ node: [String: Any], own: Set<String>) -> Frame {
        guard let image = (node["binaryUUID"] as? String).flatMap(uuid), own.contains(image),
              let offset = node["offsetIntoBinaryTextSegment"] as? Int, (0...maxOffset).contains(offset) else { return .lib }
        return Frame(image: image, offset: offset)
    }

    /// **Identical crashes are one entry** (the same signal, type, code and frames), with their count, the first time
    /// and the last; at most `maxCrashes` entries, the ones seen last, in the order they first came.
    public static func merged(_ crashes: [Crash]) -> [Crash] {
        var order: [Crash.Signature] = []
        var seen: [Crash.Signature: Crash] = [:]
        for crash in crashes {
            let key = crash.signature
            if let earlier = seen[key] { seen[key] = earlier.adding(crash) } else { order.append(key); seen[key] = crash }
        }
        let all = order.compactMap { seen[$0] }
        guard all.count > maxCrashes else { return all }
        let newest = all.indices.sorted { (all[$0].last, $0) > (all[$1].last, $1) }.prefix(maxCrashes)
        return Set(newest).sorted().map { all[$0] }
    }

    /// **The UUIDs of this app's own executable** that a crash's frames are compared with: the build that runs first,
    /// then the builds that ran before it on this Mac (`kept`), at most eight. A crash comes at the next start, which
    /// can be the start of a newer build.
    public static func ownImages(running: String?, kept: [String]) -> [String] {
        var images: [String] = []
        for image in [running].compactMap({ $0 }) + kept {
            guard let image = uuid(image), !images.contains(image) else { continue }
            images.append(image)
        }
        return Array(images.prefix(8))
    }

    /// **The item of the privacy page that says what goes and what is kept** (its anchor `error-reports`), in the
    /// language that the app shows its words in: Spanish by the rule of the prompt that the welcome page copies
    /// (`AgentPrompt.prompt(language:)`), English otherwise.
    public static func privacy(language: String?) -> URL {
        let spanish = language.map { $0 == "es" || $0.hasPrefix("es-") || $0.hasPrefix("es_") } == true
        return URL(string: spanish ? "https://platform.founderizer.com/es/privacy#error-reports"
                                   : "https://platform.founderizer.com/privacy#error-reports")!
    }

    /// The privacy page for the words that the app shows now (`Localized.bundle`).
    public static var privacyPage: URL { privacy(language: AgentPrompt.language(of: Localized.bundle)) }
}

#if os(macOS)
// ---------------------------------------------------------------- what waits for the next start

extension ErrorReport {
    /// **The crashes whose send can still go** (`ErrorReportError.keeps`), for the next start: one small file in the
    /// app's own folder (`KeptRecordsPlace`), readable by its user only, with at most `maxCrashes` entries (`keep` merges
    /// and cuts what it writes, `kept` what it reads). Nothing else is ever written: a crash that comes while the switch
    /// is off, or before the hub has said that it is on, is never on the disk. **The name is the app's own:** a file or a
    /// link at it that does not read as crashes goes at the sender's first look (`forget`), and a send that keeps writes
    /// over it (`keep`); a folder at it stays, with what is in it.
    public static var keptFile: URL { KeptRecordsPlace.folder("error-reports.json") }

    /// **What a send leaves in the kept file, and so for the next start**; it gives what the file holds then.
    /// - `fresh`: the crashes of this run that the report carried. `carriedKept`: it carried what the file held too.
    /// - `error`: nil for a 200, which takes out of the file what the report carried. One that keeps (429, 5xx, no
    ///   answer) adds `fresh` to the file; any other drops the file whole: our site will never take that payload.
    public static func settle(_ fresh: [Crash], carriedKept: Bool, after error: Error?, in file: URL = keptFile) -> [Crash] {
        guard let error else {
            if carriedKept { forget(file); return [] }
            return kept(file)
        }
        guard ErrorReportError.keeps(error) else {
            // A payload that the site refuses is dropped; a file that this batch did not carry stays as it is.
            if carriedKept { forget(file); return [] }
            return kept(file)
        }
        let held = merged((kept(file) + fresh).compactMap(\.checked))
        try? keep(held, in: file)
        return held
    }

    /// What the file holds, each entry checked again; nothing for no file, a larger one or one that does not read.
    /// Only a regular file is read, with no wait (`KeptFile`), and the size is the opened file's own: it was asked
    /// of the file's name before, so a link passed with its own few bytes, and the file behind it was then read
    /// whole, whatever its size.
    public static func kept(_ file: URL = keptFile) -> [Crash] {
        guard let data = KeptFile.bytes(of: file, atMost: 2 * maxBytes),
              let crashes = try? JSONDecoder().decode([Crash].self, from: data) else { return [] }
        return merged(crashes.compactMap(\.checked))
    }

    /// Writes the file in one step; no crash removes it.
    public static func keep(_ crashes: [Crash], in file: URL = keptFile) throws {
        let crashes = merged(crashes.compactMap(\.checked))
        guard !crashes.isEmpty else { return forget(file) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(crashes)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Removes the file, or a link at its name and never the file behind it, with one `unlink`. **A folder at the name
    /// stays, with what is in it** (`removeItem` took the folder whole until 17 November 2026): only another program of
    /// this user puts one there, `kept` reads nothing from it and `keep` cannot write over it, so no crash waits then.
    public static func forget(_ file: URL = keptFile) {
        unlink(file.path)
    }

    /// The system that runs, as the report names it: "macOS 26.6.2".
    public static var runningSystem: String { "macOS " + ProblemReport.systemVersion() }

    /// **The UUID of the executable that runs** (its `LC_UUID`), which a crash's frames of this build carry.
    public static var runningImage: String? {
        guard let header = _dyld_get_image_header(0), header.pointee.magic == UInt32(truncatingIfNeeded: MH_MAGIC_64)
        else { return nil }
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.loadUnaligned(as: load_command.self)
            if load.cmd == UInt32(truncatingIfNeeded: LC_UUID) {
                return UUID(uuid: command.loadUnaligned(as: uuid_command.self).uuid).uuidString.lowercased()
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }
}
#endif

// ---------------------------------------------------------------- sending it

/// **The one request of error reports to our own site**: `POST <channel>/api/errors`, on the rule of Report a problem
/// (`OurSite`): HTTPS on our own domain only, no redirect, no cookie, no key and no token. The fleet's id is in the
/// body; no header carries anything of the fleet.
public final class ErrorReportClient: Sendable {
    public static let path = "api/errors"
    private let session: URLSession

    /// `protocolClasses` is for a test only: it answers the request with no network.
    public init(protocolClasses: [AnyClass]? = nil) {
        session = OurSite.session(protocolClasses: protocolClasses)
    }

    /// Where the report goes: the fleet's channel when it is HTTPS on our own domain, else our own site.
    public static func endpoint(channel: String?) throws -> URL {
        guard let url = OurSite.endpoint(channel: channel, path: path) else { throw ErrorReportError.badChannel }
        return url
    }

    /// Sends the report; it throws for every answer but a 200.
    public func send(_ report: ErrorReport, channel: String?) async throws {
        var request = URLRequest(url: try Self.endpoint(channel: channel))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try report.body()
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ErrorReportError.refused(status) }
    }
}

// ---------------------------------------------------------------- the Mac's day (W17)

/// **The Mac's day** (the reliability plan of 21 November 2026, W17, inside the owner's yes to "codes, versions and
/// counts", Q3): the `app` block of the contract's "The health of a fleet". Its own update (`update`), whether it reaches
/// its hub and which release the hub runs (`hub`), and the installs that it ran and that stopped (`installs`). **Every
/// value is a word of a copy of our site's lists, a version, a whole number or a time**: never a host, a link, an
/// address, a path, a name or a line that a program wrote. The initializers check each value again, so that one value
/// outside the contract never makes our site refuse the whole report.
public struct AppHealth: Encodable, Equatable, Sendable {
    // The words: copies of our site's lists (founderizer-web, src/lib/errors.ts, HEALTH_WORDS), word for word. Our site
    // refuses a report whole when it names a word outside its list, so a word of this app's own that a copy does not
    // have goes as "other" (`word`). A new word goes to our site first, then here: ErrorReportsTests holds each copy to
    // the site's list of 21 November 2026, and each word of this app's sources to be in its copy.
    public static let updateStates = ["current", "waiting", "failed", "refused", "held", "none", "other"]
    public static let updateCauses = ["none", "dns", "connect", "tls", "http", "timeout", "disk", "manifest",
                                      "translocated", "read_only", "size", "checksum", "cannot_unpack", "not_one_app",
                                      "unreadable_bundle", "not_founderizer", "mismatch", "unsigned", "wrong_signature",
                                      "cannot_replace", "other"]
    public static let reaches = ["none", "invalid_address", "refused_this_mac", "not_a_hub", "hub_error", "refused",
                                 "unreadable", "timed_out", "no_connection", "host_not_found", "no_network",
                                 "blocked_by_app", "not_secure", "other"]
    public static let installKinds = ["hub", "server", "mac", "other"]
    public static let installStops = ["none", "cannot_start", "installer_stopped", "server_unreached", "login_refused",
                                      "step_failed", "hub_not_ours", "not_root", "timed_out", "no_claim_code",
                                      "no_checklist", "check_stopped", "needs_sudo_password", "needs_ssh_password",
                                      "network_key_refused", "hub_refused", "hub_unreached", "mac_refused",
                                      "mac_unreachable", "mac_unreadable", "other"]
    public static let installCauses = ["none", "needs_root", "system_not_supported", "no_systemd", "hub_no_answer",
                                       "code_not_fetched", "join_code_refused", "join_code_expired",
                                       "server_name_refused", "server_name_unread", "hub_busy", "private_network",
                                       "firewall", "agent_users", "vault", "updates", "packages", "service",
                                       "hub_claim", "agent_program", "homebrew", "wrong_mac_user", "other"]
    /// The stops that carry the installer's own reason (`SetupDiagnosis.stopsWithCause`): every other stop's cause is
    /// "none", as `setup_diagnosis` gives it.
    static let stopsWithCause: Set<String> = ["installer_stopped", "mac_refused"]
    /// The contract's bounds: installs in one report, tries and hours, and releases missing.
    public static let mostInstalls = 10
    public static let numberMost = 100_000
    public static let missingMost = 1000
    /// MAC_VERSION and HUB_VERSION of the contract: "0.1.430 (431)", "2026.11.762".
    static let macVersionPattern = ErrorReport.versionPattern
    static let hubVersionPattern = #"\A[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,6}\z"#

    public let update: Update
    public let hub: Hub
    /// At most `mostInstalls`: the ones that stopped last.
    public let installs: [Install]

    public init(update: Update, hub: Hub, installs: [Install]) {
        self.update = update
        self.hub = hub
        self.installs = Array(installs.compactMap(\.checked).prefix(Self.mostInstalls))
    }

    /// The word itself when the copy has it, else "other".
    static func word(_ value: String, in list: [String]) -> String { list.contains(value) ? value : "other" }

    static func count(_ value: Int, most: Int) -> Int { min(max(value, 0), most) }

    /// A Mac build's version as the contract writes it, or nil: a name that is no version of numbers is not sent.
    static func macVersion(_ value: String?) -> String? {
        value.flatMap { ErrorReport.matches($0, macVersionPattern) ? $0 : nil }
    }

    static func hubVersion(_ value: String?) -> String? {
        value.flatMap { ErrorReport.matches($0, hubVersionPattern) ? $0 : nil }
    }

    // ------------------------------------------------------------ its three parts

    /// **This Mac's own update**: its state, why its last try failed, the tries of the newest build that did not end
    /// installed, and the newest build that the channel named (nil: no answer yet).
    public struct Update: Encodable, Equatable, Sendable {
        public let state: String
        public let cause: String
        public let tries: Int
        public let newest: String?

        public init(state: String, cause: String, tries: Int, newest: String?) {
            self.state = AppHealth.word(state, in: AppHealth.updateStates)
            self.cause = AppHealth.word(cause, in: AppHealth.updateCauses)
            self.tries = AppHealth.count(tries, most: AppHealth.numberMost)
            self.newest = AppHealth.macVersion(newest)
        }

        private enum CodingKeys: String, CodingKey { case state, cause, tries, newest }

        /// Every key is there: `newest` goes as `null` when there is none.
        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(state, forKey: .state)
            try values.encode(cause, forKey: .cause)
            try values.encode(tries, forKey: .tries)
            if let newest { try values.encode(newest, forKey: .newest) } else { try values.encodeNil(forKey: .newest) }
        }
    }

    /// **Whether this Mac reaches its hub**: why not now ("none": it does), whole hours since the hub last answered it
    /// (0 with "none"), the release that the hub runs and the newest one of its track at its last answer, and how many
    /// releases of that track are newer than the one that it runs.
    public struct Hub: Encodable, Equatable, Sendable {
        public let reach: String
        public let hours: Int
        public let runs: String?
        public let newest: String?
        public let missing: Int

        public init(reach: String, hours: Int, runs: String?, newest: String?, missing: Int) {
            self.reach = AppHealth.word(reach, in: AppHealth.reaches)
            self.hours = self.reach == "none" ? 0 : AppHealth.count(hours, most: AppHealth.numberMost)
            self.runs = AppHealth.hubVersion(runs)
            self.newest = AppHealth.hubVersion(newest)
            self.missing = AppHealth.count(missing, most: AppHealth.missingMost)
        }

        private enum CodingKeys: String, CodingKey { case reach, hours, runs, newest, missing }

        /// Every key is there: `runs` and `newest` go as `null` when there is none.
        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(reach, forKey: .reach)
            try values.encode(hours, forKey: .hours)
            if let runs { try values.encode(runs, forKey: .runs) } else { try values.encodeNil(forKey: .runs) }
            if let newest { try values.encode(newest, forKey: .newest) } else { try values.encodeNil(forKey: .newest) }
            try values.encode(missing, forKey: .missing)
        }
    }

    /// **Installs of one kind that stopped so**: how many, and the first and the last time, in whole seconds.
    public struct Install: Encodable, Equatable, Sendable {
        public let kind: String
        public let stop: String
        public let cause: String
        public let count: Int
        public let first: Int
        public let last: Int

        public init(kind: String, stop: String, cause: String, count: Int, first: Int, last: Int) {
            self.kind = AppHealth.word(kind, in: AppHealth.installKinds)
            self.stop = AppHealth.word(stop, in: AppHealth.installStops)
            self.cause = AppHealth.stopsWithCause.contains(self.stop) ? AppHealth.word(cause, in: AppHealth.installCauses)
                : "none"
            self.count = count
            self.first = first
            self.last = last
        }

        /// The entry when its count and times fit the contract, else nil.
        var checked: Install? {
            guard (1...ErrorReport.maxCount).contains(count), ErrorReport.times.contains(first),
                  ErrorReport.times.contains(last), first <= last else { return nil }
            return self
        }
    }

    // ------------------------------------------------------------ from what the app knows

    /// **The update block from what this app's update knows** (`AppUpdateFacts`, `AppUpdateTries`), first match:
    /// - an install of the newest build failed (the kept tries are of a build newer than the one that runs, and no
    ///   newer build came since): `failed`, with the cause of its last try and its tries;
    /// - the reads of our channel fail (`AppUpdateFacts.fails`: for `AppUpdatePolicy.long`, more than one, and the last
    ///   one at most `ErrorReportsDay.retry` old, so a Mac that made no read, asleep or with no hub, says no failure):
    ///   `failed`, with the network's word of the last one, kept across starts;
    /// - no read reached the channel: `none`;
    /// - else the last read that reached it: `refused` (401 or 402: a status of the channel, so "http"), `held`,
    ///   `current`, `waiting` (a newer build, also one that waits for a newer macOS), or `failed` for a manifest that
    ///   did not verify ("manifest"), another status ("http") or a read that asked nothing ("other").
    public static func update(_ facts: AppUpdateFacts, tries kept: AppUpdateTries?, running: AppVersion?,
                              now: Date) -> Update {
        let manifest = facts.reached?.manifest
        let newest = manifest.map { "\($0.version) (\($0.build))" }
        if let kept, running.map({ kept.build > $0.build }) ?? true, manifest.map({ kept.build >= $0.build }) ?? true {
            return Update(state: "failed", cause: kept.cause, tries: kept.tries, newest: newest)
        }
        if let failing = facts.failing, facts.fails(now: now) {
            return Update(state: "failed", cause: failing.cause, tries: 0, newest: newest)
        }
        guard let reading = facts.reached else { return Update(state: "none", cause: "none", tries: 0, newest: nil) }
        let state: (String, String)
        if reading.refused { state = ("refused", "http") }
        else if manifest?.hold == true { state = ("held", "none") }
        else if reading.current { state = ("current", "none") }
        else if reading.offered { state = ("waiting", "none") }
        else if let manifest, let running, manifest.build > running.build { state = ("waiting", "none") }
        else if reading.status == 200 { state = manifest == nil ? ("failed", "manifest") : ("other", "none") }
        else if reading.status == 0 { state = ("failed", "other") }
        else { state = ("failed", "http") }
        return Update(state: state.0, cause: state.1, tries: 0, newest: newest)
    }

    /// Why a read of our channel did not reach it: a status of the channel (a 5xx) is "http", no answer the network's
    /// word of its `URLError`.
    static func readCause(_ reading: AppUpdateReading?) -> String {
        guard let reading else { return "other" }
        if reading.status != 0 { return "http" }
        return reading.urlError.map { networkCause(URLError.Code(rawValue: $0)) } ?? "other"
    }

    /// **The cause word of an error that stopped an update** (agreed with the Release area, 21 November 2026): each case
    /// of `AppUpdateFailure` by its own word, a download's status as "http", and the network's words.
    public static func updateCause(_ error: Error) -> String {
#if os(macOS)
        if let failure = error as? AppUpdateFailure {
            // Exhaustive: a new case of AppUpdateFailure fails the build here, so that it gets its word.
            switch failure {
            case .manifest: return "manifest"
            case .translocated: return "translocated"
            case .readOnly: return "read_only"
            case .download: return "http"
            case .size: return "size"
            case .checksum: return "checksum"
            case .cannotUnpack: return "cannot_unpack"
            case .notOneApp: return "not_one_app"
            case .unreadableBundle: return "unreadable_bundle"
            case .notFounderizer: return "not_founderizer"
            case .mismatch: return "mismatch"
            case .unsigned: return "unsigned"
            case .wrongSignature: return "wrong_signature"
            case .cannotReplace: return "cannot_replace"
            }
        }
#endif
        if let failure = error as? URLError { return networkCause(failure.code) }
        if let failure = error as? CocoaError, failure.code == .fileWriteOutOfSpace { return "disk" }
        if let failure = error as? POSIXError, failure.code == .ENOSPC { return "disk" }
        return "other"
    }

    static func networkCause(_ code: URLError.Code) -> String {
        switch code {
        case .cannotFindHost, .dnsLookupFailed: "dns"
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet: "connect"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired: "tls"
        case .timedOut: "timeout"
        case .badServerResponse: "http"
        case .cannotCreateFile, .cannotOpenFile, .cannotCloseFile, .cannotWriteToFile, .cannotRemoveFile,
             .cannotMoveFile: "disk"
        default: "other"
        }
    }

    /// **The hub block**: `reach`, the kind of the last read of the hub (`ReachFacts.readKind`), and the hours since
    /// `answered`, the hub's last answer to this Mac; the releases from the hub's last answer (`HubReleases`).
    public static func hub(reach: ReachFacts.ReadKind, answered: Date?, releases: HubReleases?, now: Date) -> Hub {
        let hours = answered.map { min(Double(numberMost), max(0, now.timeIntervalSince($0) / 3600)) } ?? 0
        return Hub(reach: reach.rawValue, hours: Int(hours), runs: releases?.runs, newest: releases?.newest,
                   missing: releases?.missing ?? 0)
    }

    /// **The hub's releases as the day names them**, from its releases reading (`GET /ui/releases`): the release that
    /// it runs (`ReleaseState.current`), the newest that its channel named, and the releases above the one that it
    /// runs that are not held (all of them while it runs none). Kept with the switch's last answer
    /// (`ErrorReportsDay.Answer`) for a day whose hub does not answer.
    public struct HubReleases: Codable, Equatable, Sendable {
        public let runs: String?
        public let newest: String?
        public let missing: Int

        public init(runs: String?, newest: String?, missing: Int) {
            self.runs = AppHealth.hubVersion(runs)
            self.newest = AppHealth.hubVersion(newest)
            self.missing = AppHealth.count(missing, most: AppHealth.missingMost)
        }

        public init(_ state: ReleaseState) {
            let current = state.current
            let above = current.flatMap { run in state.releases.firstIndex { $0.id == run.id } } ?? state.releases.endIndex
            self.init(runs: current?.version, newest: state.releases.first?.version,
                      missing: state.releases[..<above].filter { !$0.hold }.count)
        }
    }

    /// **The installs that stopped after `since`**: one entry for each kind, stop and cause, with how many and the
    /// first and the last time; the `mostInstalls` that stopped last.
    public static func installs(_ stops: [InstallStop], since: Date) -> [Install] {
        struct Key: Hashable { let kind, stop, cause: String }
        var found: [Key: (count: Int, first: Int, last: Int)] = [:]
        for stop in stops where stop.at > since {
            let seconds = stop.at.timeIntervalSince1970
            guard seconds.isFinite, Double(ErrorReport.times.lowerBound) <= seconds,
                  seconds <= Double(ErrorReport.times.upperBound) else { continue }
            let at = Int(seconds)
            let entry = Install(kind: stop.kind, stop: stop.stop, cause: stop.cause, count: 1, first: at, last: at)
            let key = Key(kind: entry.kind, stop: entry.stop, cause: entry.cause)
            let before = found[key]
            found[key] = (min((before?.count ?? 0) + 1, ErrorReport.maxCount), min(before?.first ?? at, at),
                          max(before?.last ?? at, at))
        }
        return found.map { Install(kind: $0.key.kind, stop: $0.key.stop, cause: $0.key.cause, count: $0.value.count,
                                   first: $0.value.first, last: $0.value.last) }
            .sorted { ($0.last, $0.kind, $0.stop, $0.cause) > ($1.last, $1.kind, $1.stop, $1.cause) }
            .prefix(mostInstalls).map { $0 }
    }
}

/// **One install that stopped**, by the fixed names of the app's records (`InstallRecord`): its kind as the contract
/// names it ("server" for a join), its stop, its cause, and when it stopped.
public struct InstallStop: Equatable, Sendable {
    public let kind: String
    public let stop: String
    public let cause: String
    public let at: Date

    public init(kind: String, stop: String, cause: String, at: Date) {
        self.kind = kind
        self.stop = stop
        self.cause = cause
        self.at = at
    }
}

#if os(macOS)
extension InstallStop {
    /// The stops in the app's kept records: a record that stopped, with its fixed names and its end. Never its hub, its
    /// host, its server's name, its id or its line (`says`).
    public static func of(_ records: [InstallRecord]) -> [InstallStop] {
        records.compactMap { record in
            guard record.outcome == .stopped, let stop = record.stop, let ended = record.ended else { return nil }
            let kind = switch record.kind {
            case .hub: "hub"
            case .join: "server"
            case .mac: "mac"
            }
            return InstallStop(kind: kind, stop: stop.rawValue, cause: record.cause?.rawValue ?? "none", at: ended)
        }
    }
}
#endif

// ---------------------------------------------------------------- what the app's update came to

/// **What this Mac's own update came to**, for the day's report (`AppHealth.update`): the app's update
/// (`AppAutoUpdate`) gives it each read of our channel. The last read that reached the channel is in memory; **the reads
/// that fail now are kept in the app's defaults** (`Failing`), so that a Mac whose app starts again each day still says
/// "failed", with the network's word, after a day of reads that fail; the first read that reaches the channel ends them.
/// The tries of a build are kept apart (`AppUpdateTries`).
public struct AppUpdateFacts: Equatable, Sendable {
    static let failingKey = "errorReportsUpdateFailing"

    /// **The reads of our channel that fail now**: since when, the last one, how many, and the cause word of the last
    /// one (`AppHealth.readCause`). Times in seconds since 1970.
    public struct Failing: Codable, Equatable, Sendable {
        public var since: Double
        public var last: Double
        public var count: Int
        public var cause: String
    }

    /// The last read that reached the channel, or nil before one in this start.
    public private(set) var reached: AppUpdateReading?
    /// The reads that fail now, in any start, or nil.
    public private(set) var failing: Failing?

    /// The facts at a start of the app: no read yet, and the kept reads that fail (times written while the clock was
    /// more than a day ahead count as none).
    public init(at now: Date = Date(), in defaults: UserDefaults = AppDefaults.store) {
        failing = defaults.data(forKey: Self.failingKey)
            .flatMap { try? JSONDecoder().decode(Failing.self, from: $0) }
            .flatMap { ErrorReportsDay.valid($0.since, now: now) != nil && ErrorReportsDay.valid($0.last, now: now) != nil
                ? $0 : nil }
    }

    /// One read of the channel.
    public mutating func read(_ reading: AppUpdateReading, at now: Date = Date(),
                              in defaults: UserDefaults = AppDefaults.store) {
        if reading.unreachable {
            let at = now.timeIntervalSince1970
            var next = failing ?? Failing(since: at, last: at, count: 0, cause: "other")
            next.last = at
            next.count = min(next.count + 1, AppHealth.numberMost)
            next.cause = AppHealth.readCause(reading)
            failing = next
            if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.failingKey) }
        } else {
            reached = reading
            if failing != nil || defaults.object(forKey: Self.failingKey) != nil {
                defaults.removeObject(forKey: Self.failingKey)
            }
            failing = nil
        }
    }

    /// **The reads of our channel fail now**: the first one failed `AppUpdatePolicy.long` ago or more, more than one
    /// failed, and the last one is at most `ErrorReportsDay.retry` old. A Mac that made no read in that time (asleep,
    /// its hub silent, the app not running) says nothing of a failure.
    public func fails(now: Date) -> Bool {
        guard let failing else { return false }
        let at = now.timeIntervalSince1970
        return at - failing.since >= AppUpdatePolicy.long && failing.count > 1
            && at - failing.last <= ErrorReportsDay.retry
    }
}

/// **The install tries of one build that did not end installed**, with the cause word of the last one
/// (`AppHealth.updateCause`), kept in the app's defaults across its starts: a build and two small values, no words of
/// an error. A try of another build starts the count again; a build that runs, or a newer one that the channel names,
/// ends it (`AppHealth.update`).
public struct AppUpdateTries: Codable, Equatable, Sendable {
    static let key = "errorReportsUpdateTries"
    public let build: Int
    public let tries: Int
    public let cause: String

    public init(build: Int, tries: Int, cause: String) {
        self.build = build
        self.tries = tries
        self.cause = cause
    }

    public static func kept(in defaults: UserDefaults = AppDefaults.store) -> AppUpdateTries? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AppUpdateTries.self, from: $0) }
    }

    /// A try of `build` failed with `error`.
    public static func failed(build: Int, error: Error, in defaults: UserDefaults = AppDefaults.store) {
        let before = kept(in: defaults).flatMap { $0.build == build ? $0.tries : nil } ?? 0
        let tries = AppUpdateTries(build: build, tries: min(before + 1, AppHealth.numberMost),
                                   cause: AppHealth.updateCause(error))
        if let data = try? JSONEncoder().encode(tries) { defaults.set(data, forKey: key) }
    }
}

// ---------------------------------------------------------------- when the day goes, and on which answer

/// **The Mac's day goes once a day, while the owner's switch is on** (W17, and the plan's Q5; the owner's answer of 22
/// November 2026: the Mac sends on the switch's last answer "on" for one day while it does not reach its hub). Before a report, the sender asks the hub for the switch,
/// as before; each answer is kept here with its time (`take`), the hub's address, and with an answer "on" the fleet's
/// id, its channel and the hub's releases of that moment. **When the hub does not answer** (it is down, or the Mac's
/// hub does not exist yet), the day's report goes on that last answer when it is on, of the same hub, at most `lasts`
/// old, after the hub has been silent for `patience` (`lastAnswer`). Never on an answer that is off (a "no" on the
/// first run's page is one, `FirstRunReports.choose`), never on another hub's answer, never with no answer at all. A
/// connect to another hub and "Start again" forget the answer (`forget`).
///
/// **The block comes to our site first.** When our site answers 400 to a report with the day, the same report goes
/// again at once without it when it has crashes, and the day waits a day (`deliver`), so a site that does not take
/// the block yet costs no crash. The day's times are in the app's defaults: no work, no name and no key.
public enum ErrorReportsDay {
    /// Between two days' reports, and the wait of the block after our site refused it.
    public static let day: TimeInterval = 86_400
    /// After a send that may go again (a 429, a 5xx, no answer), or a switch that did not answer: the next try.
    public static let retry: TimeInterval = 3_600
    /// The oldest answer of the switch that a day may go on (Q5; the owner's answer of 22 November 2026: one day).
    public static let lasts: TimeInterval = 86_400
    /// How long the hub is silent, in time awake (the uptime: a sleep of the Mac is no silence of the hub), before the
    /// day goes on the last answer: a read that fails once is no hub that is down.
    public static let patience: TimeInterval = 15 * 60
    /// While the hub answers, the switch is read at least this often, so that its last answer is new when the hub goes.
    public static let look: TimeInterval = 3_600
    static let answerKey = "errorReportsAnswer"
    static let stateKey = "errorReportsDay"

    /// **The switch's last answer**: on or off, its time, the hub that gave it (its address in the app's own form,
    /// which never leaves this Mac), and with an answer that is on, what a report on it needs.
    public struct Answer: Codable, Equatable, Sendable {
        public let send: Bool
        /// Seconds since 1970.
        public let at: Double
        public let hub: String?
        public let fleet: String?
        public let channel: String?
        public let releases: AppHealth.HubReleases?
        /// **The first answer "on" of this run of answers "on" of the same hub**, in seconds since 1970, never after
        /// `at`: the start of the installs that a report may carry (`installsSince`). nil in an answer "off", and in an
        /// answer that an app from before this field kept (then `at` stands for it).
        public let since: Double?
    }

    /// What the hub said of the switch now: on (with its releases reading, when the sender has one), off (a hub that
    /// does not offer the switch is off too), or nothing.
    public enum Switch: Sendable {
        case on(ReleaseState?)
        case off
        case noAnswer
    }

    /// The day's times: the last day that went (or that our site refused for good), the next try after a failed one,
    /// the end of the block's wait, the last report with the block that our site took, and the hub's last answer.
    struct State: Codable, Equatable {
        var sent: Double?
        var retry: Double?
        var hold: Double?
        var taken: Double?
        var hub: Double?
    }

    static func state(in defaults: UserDefaults) -> State {
        defaults.data(forKey: stateKey).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    static func save(_ state: State, in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: stateKey) }
    }

    /// A time, or nil for one more than a day after `now`: it was written while the clock was ahead, and must not stop
    /// the reports for long.
    static func valid(_ time: Double?, now: Date) -> Double? {
        time.flatMap { $0.isFinite && $0 <= now.timeIntervalSince1970 + day ? $0 : nil }
    }

    /// The switch's last answer, as it is kept.
    public static func lastAnswer(in defaults: UserDefaults = AppDefaults.store) -> Answer? {
        defaults.data(forKey: answerKey).flatMap { try? JSONDecoder().decode(Answer.self, from: $0) }
    }

    /// **What the hub at `hub` said of the switch**, kept as its last answer, and **the answer that a report goes on
    /// now**: the hub's own when it is on; nil when it is off; with no answer, the last one when it is on, of this same
    /// hub, at most `lasts` old, with a fleet's id, and the owner's newest answer on the first run's page is not "no".
    /// An answer "on" with no releases reading (a look at the switch before the store read them) keeps the fleet's id,
    /// the channel and the releases of the kept answer "on" of the same hub, with its own time.
    @discardableResult
    public static func take(_ answer: Switch, hub: String? = nil, now: Date = Date(),
                            in defaults: UserDefaults = AppDefaults.store) -> Answer? {
        let at = now.timeIntervalSince1970
        switch answer {
        case .off:
            keep(Answer(send: false, at: at, hub: hub, fleet: nil, channel: nil, releases: nil, since: nil), in: defaults)
            return nil
        case .on(let releases):
            return keepOn(releases, hub: hub, at: at, start: at, in: defaults)
        case .noAnswer:
            guard let hub, let kept = lastAnswer(in: defaults), kept.send, kept.hub == hub,
                  let time = valid(kept.at, now: now), at - time <= lasts, let fleet = kept.fleet, FleetID.isValid(fleet),
                  FirstRunReports.waiting(in: defaults) != false else { return nil }
            return kept
        }
    }

    private static func keep(_ answer: Answer, in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(answer) { defaults.set(data, forKey: answerKey) }
    }

    /// An answer "on" of `hub` at `at`, kept: the run of answers "on" goes on from the answer before, of this same hub,
    /// and starts at `start` when that is earlier; an answer "off" (the switch, a first-run "Don't send", a hub with no
    /// switch), another hub's answer and no answer start a new run. The start is never after `at`.
    private static func keepOn(_ releases: ReleaseState?, hub: String?, at: Double, start: Double,
                               in defaults: UserDefaults) -> Answer {
        let before = lastAnswer(in: defaults).flatMap { $0.send && $0.hub == hub && hub != nil ? $0 : nil }
        let fleet = releases.map { $0.entitlement.fleet.flatMap { FleetID.isValid($0) ? $0 : nil } } ?? before?.fleet
        let since = min(before.map { $0.since ?? $0.at } ?? start, start, at)
        let kept = Answer(send: true, at: at, hub: hub, fleet: fleet, channel: releases?.channel ?? before?.channel,
                          releases: releases.map(AppHealth.HubReleases.init) ?? before?.releases, since: since)
        keep(kept, in: defaults)
        return kept
    }

    /// **The hub at `hub` took a press "on" of the owner at `press`** (the second reader's R2-M1 of F5 piece 4): the
    /// first run's "Send" when its hub took it (`FirstRunReportsSender`, with `FirstRunReports.pressed`), or the switch
    /// of Settings › Help that he turned on (`ErrorReportsModel.turn`). The switch's answer "on" of that hub is kept,
    /// with its run started at his press, never after now. So the stops after his press go, also the stops of a first
    /// run after its hub answered with its switch still off, which waited for the end of the first run; and the hour
    /// before this Mac's next read of the switch loses nothing. The stops before his press stay out, and so do the stops
    /// of an earlier "Don't send", because each press moves it. Only a hub's receipt calls it.
    public static func pressedOn(hub: String, at press: Date, now: Date = Date(),
                                 in defaults: UserDefaults = AppDefaults.store) {
        _ = keepOn(nil, hub: hub, at: now.timeIntervalSince1970, start: press.timeIntervalSince1970, in: defaults)
    }

    /// **The Mac leaves its hub** (a connect to another hub, "Start again"): the switch's last answer and the hub's last
    /// answer go, so that no day goes for a fleet that the Mac left and no hours count from its hub.
    public static func forget(in defaults: UserDefaults = AppDefaults.store) {
        defaults.removeObject(forKey: answerKey)
        var state = state(in: defaults)
        guard state.hub != nil else { return }
        state.hub = nil
        save(state, in: defaults)
    }

    /// **The day's report is due**: none went in the last `day`, no failed try waits for `retry`, and the block does
    /// not wait after a refusal.
    public static func due(now: Date = Date(), in defaults: UserDefaults = AppDefaults.store) -> Bool {
        let state = state(in: defaults), at = now.timeIntervalSince1970
        if let retry = valid(state.retry, now: now), at < retry { return false }
        if let hold = valid(state.hold, now: now), at < hold { return false }
        return valid(state.sent, now: now).map { at - $0 >= day } ?? true
    }

    /// While the hub answers: the switch's last answer is `look` old or more, so the sender reads it again.
    public static func shouldLook(now: Date = Date(), in defaults: UserDefaults = AppDefaults.store) -> Bool {
        valid(lastAnswer(in: defaults)?.at, now: now).map { now.timeIntervalSince1970 - $0 >= look } ?? true
    }

    /// **The hub answered this Mac** at `answered` (`FleetStore.lastSuccess`): kept when it is a minute newer than the
    /// kept time, so that the hours of a hub that does not answer count across starts of the app.
    public static func noteHub(answered: Date?, in defaults: UserDefaults = AppDefaults.store) {
        guard let answered else { return }
        var state = state(in: defaults)
        let at = answered.timeIntervalSince1970
        if let kept = state.hub, at < kept + 60, at >= kept { return }
        state.hub = at
        save(state, in: defaults)
    }

    /// The hub's last answer to this Mac that is kept: the newer of `noteHub`'s and the switch's last answer.
    public static func hubAnswered(now: Date = Date(), in defaults: UserDefaults = AppDefaults.store) -> Date? {
        let times = [valid(state(in: defaults).hub, now: now), valid(lastAnswer(in: defaults)?.at, now: now)]
        return times.compactMap { $0 }.max().map { Date(timeIntervalSince1970: $0) }
    }

    /// **The installs that the day names stopped after this**: the last report with the block that our site took, or a
    /// `day` ago before the first one, and never before the switch's kept answer "on" began its run (`Answer.since`):
    /// no install that stopped while the switch was off, or while a first-run "Don't send" stood, goes after the next
    /// "on" (the second reader's M3; the owner's claim 5 of the F5 analysis, "Nothing from before his yes goes", which
    /// the crashes keep). The run starts at his press when this Mac made it and the hub took it (`pressedOn`: the first
    /// run's "Send", Settings › Help), else at this Mac's first read "on", at most an hour after a press on another
    /// device: the stops of that hour go in no report, which fails closed. An answer kept by a build before this field
    /// has no start, and its own time stands for it: once, at that update, the stops between the last report that our
    /// site took and that answer's time go in none. A start ahead of the clock counts as now.
    ///
    /// **A known limit** (the second reader's R2-N3): a run can start before the true "on". When another device turns
    /// the switch off and on again between two reads of this Mac (its hourly look), or while the hub is silent, this Mac
    /// never sees the "off", its run goes on, and a stop of that time can go. The hub's own time of its last "on" in its
    /// answer to `GET /ui/error-reports` would close it; that is a change of the owner API, not made here.
    ///
    /// **A second known limit** (the validator of 22 November 2026): a stop of a time while the switch was off, on a
    /// clock that ran ahead and was then put right, carries a time after the run's start, and it can go.
    public static func installsSince(now: Date = Date(), in defaults: UserDefaults = AppDefaults.store) -> Date {
        let base = valid(state(in: defaults).taken, now: now) ?? now.addingTimeInterval(-day).timeIntervalSince1970
        let floor = lastAnswer(in: defaults).flatMap { $0.send ? min($0.since ?? $0.at, now.timeIntervalSince1970) : nil }
        return Date(timeIntervalSince1970: max(base, floor ?? base))
    }

    /// **The answer that the day goes on while the hub at `hub` does not answer**: the day is due, the hub has been
    /// silent for `patience` or more of time awake (`silentFor`, on the uptime), and `take(.noAnswer)` gives an answer
    /// of that hub.
    public static func lastAnswer(hub: String, silentFor: TimeInterval?, now: Date = Date(),
                                  in defaults: UserDefaults = AppDefaults.store) -> Answer? {
        guard let silentFor, silentFor >= patience, due(now: now, in: defaults) else { return nil }
        return take(.noAnswer, hub: hub, now: now, in: defaults)
    }

    /// **A press of the switch that got no answer** (Settings › Help, `ErrorReportsModel.turn`): a press "off" whose
    /// call ended with no answer of the hub keeps the switch's last answer "off" on this Mac, because the hub may have
    /// taken it. A refusal is the hub's answer: the switch stays as the hub has it.
    public static func pressKeepsOff(_ on: Bool, after error: Error) -> Bool {
        guard !on else { return false }
        if let refused = error as? HubError, case .refusal = refused { return false }
        return true
    }

    /// The day's report could not be made, or the switch did not answer: it tries again after `retry`.
    public static func tryAgain(at now: Date = Date(), in defaults: UserDefaults = AppDefaults.store) {
        var state = state(in: defaults)
        state.retry = now.timeIntervalSince1970 + retry
        save(state, in: defaults)
    }

    /// **One send of a report, and what it leaves for the day.** After a 400 to a report with the block, the block
    /// waits a `day`, and the same report goes again at once without it when it carries crashes, while the switch is
    /// still on (`stillOn`): a day alone goes no more, so no empty report goes. A report with the block that our site
    /// took moves the start of the next day's installs (`installsSince`); one that went without it moves nothing. For
    /// the day's report (`day`): a send that may go again (`ErrorReportError.keeps`) tries again after `retry`; any
    /// other end, a 200 too, is the day's. It gives the error of the last send, or nil for a 200, for the crashes that
    /// the report carried (`ErrorReport.settle`).
    @discardableResult
    public static func deliver(_ report: ErrorReport, day isDay: Bool, at stamp: Date = Date(),
                               in defaults: UserDefaults = AppDefaults.store,
                               isolation: isolated (any Actor)? = #isolation, stillOn: () -> Bool = { true },
                               send: (ErrorReport) async throws -> Void) async -> Error? {
        var report = report
        var failure: Error?
        let at = stamp.timeIntervalSince1970
        while true {
            do { try await send(report); failure = nil } catch { failure = error }
            guard report.app != nil, case .refused(400)? = failure as? ErrorReportError else { break }
            var state = state(in: defaults)
            state.hold = at + day
            save(state, in: defaults)
            guard stillOn() else { return failure }
            guard !report.crashes.isEmpty else { break }
            report = report.withoutApp
        }
        var state = state(in: defaults)
        if failure == nil, report.app != nil { state.taken = at }
        if isDay {
            if let failure, ErrorReportError.keeps(failure) {
                state.retry = at + retry
            } else {
                state.sent = at
                state.retry = nil
            }
        }
        save(state, in: defaults)
        return failure
    }
}

#if os(macOS)
// ---------------------------------------------------------------- the sender's rules

/// **The rules of the Mac's sends to our own site** (the app's `ErrorReportsSender` gives it the store's facts at each
/// tick, and the calls to the hub and to our site; this type decides). **The crashes go only while the owner's switch is
/// on, at that moment**: before each send it asks the hub (`GET /ui/error-reports`); off, or a hub with no switch, drops
/// them, and nothing of them is kept; on, they go with the fleet's id and the channel of the hub's own releases read
/// (`GET /ui/releases`), as Report a problem names them. A send that can still go (our site's 429 or 5xx, or no answer,
/// or no releases read) keeps them in one small file (`ErrorReport.keptFile`, at most 20 entries), which goes again with
/// the next report of this start, or an hour after the last try (the F5 analysis of 22 November 2026, piece 5: an app
/// that stays open for weeks), and at the next start; it is deleted after a 200, and as soon as the switch is found off.
/// Any other answer of the site (400, another 4xx) drops them and the file (`ErrorReport.settle`).
///
/// **And the Mac's day, once a day** (W17, `ErrorReportsDay`): its update, its hub and its installs that stopped
/// (`AppHealth`), also on a day with no crash, in the report of the crashes that wait then, or alone. While the hub
/// answers, the day goes only after a new read of the switch says on, never on the kept answer; a switch that did not
/// answer moves the day by `ErrorReportsDay.retry`; a switch that read off is read again only at the hourly look
/// (`ErrorReportsDay.look`). When the hub does not answer, the day goes on the switch's last answer (Q5). No day goes
/// while the owner's answer of the first run's page, "no", waits for a hub (`FirstRunReports.waiting`).
///
/// It works under the hood, from the store's own loop (`tick`), and only while something waits: a crash, the day, or
/// the look at the switch. A crash that came before the hub answered waits in memory; the disk holds none that the hub
/// did not first say may go.
@MainActor public final class ErrorReportsSending {
    /// What one tick reads of the store.
    public struct Tick: Sendable {
        /// The hub's address now (`FleetStore.hub`), in the app's own form: it ties the switch's answer to its hub.
        public var hub: String
        /// The hub's generation while the hub answers now (`FleetStore.isFresh`), else nil.
        public var database: String?
        /// The hub offers the switch (owner feature `error_reports`).
        public var offered: Bool
        /// The hub's last answer to this Mac (`FleetStore.lastSuccess`).
        public var answered: Date?
        /// Why the last read of the hub failed (`ReachFacts.readKind`), for a day whose hub does not answer.
        public var reach: ReachFacts.ReadKind

        public init(hub: String, database: String?, offered: Bool, answered: Date?, reach: ReachFacts.ReadKind) {
            self.hub = hub
            self.database = database
            self.offered = offered
            self.answered = answered
            self.reach = reach
        }
    }

    /// The calls of one tick: to the hub of that tick (its switch, its releases), the store's own releases reading of
    /// its generation (for the day alone), what the day reads of the app, and the send to our site.
    public struct Calls {
        public var readSwitch: @MainActor () async throws -> Bool
        public var readReleases: @MainActor () async -> ReleaseState?
        public var storeReleases: @MainActor () -> ReleaseState?
        public var sources: @MainActor () -> Sources
        public var send: @MainActor (ErrorReport, String?) async throws -> Void

        public init(readSwitch: @escaping @MainActor () async throws -> Bool,
                    readReleases: @escaping @MainActor () async -> ReleaseState?,
                    storeReleases: @escaping @MainActor () -> ReleaseState?, sources: @escaping @MainActor () -> Sources,
                    send: @escaping @MainActor (ErrorReport, String?) async throws -> Void) {
            self.readSwitch = readSwitch
            self.readReleases = readReleases
            self.storeReleases = storeReleases
            self.sources = sources
            self.send = send
        }
    }

    /// What the day reads of the app at its send: the update's reads, the build that runs, the installs that stopped.
    public struct Sources: Sendable {
        public var update: AppUpdateFacts
        public var running: AppVersion?
        public var stops: [InstallStop]

        public init(update: AppUpdateFacts, running: AppVersion?, stops: [InstallStop]) {
            self.update = update
            self.running = running
            self.stops = stops
        }
    }

    private static let log = Logger(subsystem: "com.founderizer.app", category: "error-reports")
    private let file: URL
    private let defaults: UserDefaults
    private let version: String?
    private let system: String?
    private let now: @MainActor () -> Date
    private let uptime: @MainActor () -> TimeInterval
    private let remember: @MainActor () -> Void
    /// The crashes of this run that wait for the hub's answer: in memory only.
    private var fresh: [ErrorReport.Crash] = []
    /// What the file holds, read at the first tick of this start.
    private var onDisk: [ErrorReport.Crash]?
    /// The last try of the file in this start: what failed goes again with the next report, or `ErrorReportsDay.retry`
    /// after this.
    private var diskTriedAt: Date?
    private var working = false
    /// Each time the switch was found off: an attempt on its way then keeps nothing.
    private var offs = 0
    /// No attempt before this moment, after a hub that did not answer the switch's read.
    private var notBefore: Date?
    /// The last time the switch was read for a kept file alone (nothing else waiting).
    private var lastLook: Date?
    /// The last time the switch was read, in this start: at most once in `ErrorReportsDay.look` for the look alone.
    private var lastSwitchLook: Date?
    /// Since when the hub has not answered this Mac, in this start, on the uptime: a sleep is no silence of the hub.
    private var silentSince: TimeInterval?
    /// The line that this build's version has no form of the contract is written once in a start.
    private var saidVersion = false

    /// - Parameters: `file`, the kept file of the crashes; `version` and `system`, this build's (`ErrorReport.version`,
    ///   `ErrorReport.runningSystem`); `remember`, the note of the build that runs (`CrashSubscriber.remember`), called
    ///   when the hub said that the switch is on. `now`, `uptime` (time awake, which stops while the Mac sleeps) and
    ///   `defaults` are a test's own.
    public init(file: URL, version: String?, system: String?, defaults: UserDefaults = AppDefaults.store,
                now: @escaping @MainActor () -> Date = { Date() },
                uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                remember: @escaping @MainActor () -> Void = {}) {
        self.file = file
        self.version = version
        self.system = system
        self.defaults = defaults
        self.now = now
        self.uptime = uptime
        self.remember = remember
    }

    /// Crashes of this run (MetricKit gives them at a start).
    public func take(_ crashes: [ErrorReport.Crash]) { fresh = ErrorReport.merged(fresh + crashes) }

    /// **The switch is off**: nothing waits, the file is gone, and the switch's last answer is off, so that no day goes
    /// on an older answer while the hub does not answer. The switch of Settings, a hub's reading that says off and a
    /// hub with no switch all end here.
    public func off() {
        offs += 1
        fresh = []
        onDisk = []
        ErrorReport.forget(file)
        ErrorReportsDay.take(.off, now: now(), in: defaults)
    }

    /// **One tick of the store's loop.** It gives the task of an attempt that it started, or nil.
    @discardableResult
    public func tick(_ tick: Tick, calls: Calls) -> Task<Void, Never>? {
        let now = self.now()
        ErrorReportsDay.noteHub(answered: tick.answered, in: defaults)
        silentSince = tick.database != nil ? nil : silentSince ?? uptime()
        if onDisk == nil {
            onDisk = ErrorReport.kept(file)
            if onDisk?.isEmpty == true { ErrorReport.forget(file) }   // a file that holds no crash is no file
        }
        // The day: due, and no "no" of the owner's first run waits for a hub.
        let day = ErrorReportsDay.due(now: now, in: defaults) && FirstRunReports.waiting(in: defaults) != false
        // The kept file goes with the next report (new crashes, the day), or an hour after its last try.
        let retryDisk = diskTriedAt.map { now.timeIntervalSince($0) >= ErrorReportsDay.retry || now < $0 } ?? true
        let disk = retryDisk || !fresh.isEmpty || day ? onDisk ?? [] : []
        // A file kept after a failed send: the switch is read again each minute, so that a switch-off deletes it.
        let look = diskTriedAt != nil && fresh.isEmpty && onDisk?.isEmpty == false
            && lastLook.map { now.timeIntervalSince($0) >= 60 } ?? true
        // The switch's last answer stays new while the hub answers, so that it is the owner's when the hub goes.
        let switchLook = ErrorReportsDay.shouldLook(now: now, in: defaults)
            && lastSwitchLook.map { now.timeIntervalSince($0) >= ErrorReportsDay.look } ?? true
        // A switch that read off asks the hub again only at that look, not for the day at each tick.
        let switchOff = ErrorReportsDay.lastAnswer(in: defaults)?.send == false
        guard !working, notBefore.map({ now >= $0 }) ?? true else { return nil }
        guard tick.database != nil else {
            // The hub does not answer: only the day goes, on the switch's last answer of this hub (Q5).
            guard day, let answer = ErrorReportsDay.lastAnswer(hub: tick.hub, silentFor: silentSince.map { uptime() - $0 },
                                                                now: now, in: defaults) else { return nil }
            return run { await self.dayOnLastAnswer(answer, reach: tick.reach, calls: calls) }
        }
        guard !fresh.isEmpty || !disk.isEmpty || look || switchLook || (day && !switchOff) else { return nil }
        let batch = fresh
        if disk.isEmpty && batch.isEmpty { lastLook = now }
        lastSwitchLook = now
        fresh = []
        return run { await self.attempt(batch, disk: disk, hub: tick.hub, offered: tick.offered, day: day, calls: calls) }
    }

    private func run(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        working = true
        return Task { @MainActor in
            await body()
            self.working = false
        }
    }

    /// The hub answers: the switch is read now, and only its answer lets anything go.
    private func attempt(_ batch: [ErrorReport.Crash], disk: [ErrorReport.Crash], hub: String, offered: Bool, day: Bool,
                         calls: Calls) async {
        let offsAtStart = offs
        guard offered else { return off() }         // a hub with no switch: it is off
        let on: Bool
        do { on = try await calls.readSwitch() } catch {
            // The switch did not answer: the crashes wait in memory, and the next try is a minute away; the day's, an
            // hour away, and never on the kept answer while the hub answers.
            fresh = ErrorReport.merged(batch + fresh)
            notBefore = now().addingTimeInterval(60)
            if day { ErrorReportsDay.tryAgain(at: now(), in: defaults) }
            return
        }
        guard offs == offsAtStart else { return }
        guard on else { return off() }
        remember()
        let crashes = !(batch.isEmpty && disk.isEmpty)
        var read: ReleaseState?
        if crashes || day { read = await calls.readReleases() }
        guard offs == offsAtStart else { return }
        // The kept answer has the fleet's id and channel of the hub's releases: its own read, or the store's reading.
        // While the owner's "no" of a first run waits for this hub, also one that he gave during these reads, the hub's
        // "on" is kept as no answer and no day goes.
        let known = read ?? calls.storeReleases()
        let firstRunNo = FirstRunReports.waiting(in: defaults) == false
        let day = day && !firstRunNo
        if !firstRunNo { ErrorReportsDay.take(.on(known), hub: hub, now: now(), in: defaults) }
        guard crashes || day else { return }   // only a look at the switch: the file was tried at this start
        let stamp = now()
        // The hub answered the switch now: its reach is "none" in this day, whatever an earlier read gave.
        let app = day ? health(releases: known.map(AppHealth.HubReleases.init), reach: .none, at: stamp, calls: calls) : nil
        let stillOn = { self.offs == offsAtStart }
        // The crashes go as before W17: with the hub's own releases read of this attempt, or not at all (they wait).
        var failure: Error? = ErrorReportError.unready
        var dayWent = false
        if crashes, let read {
            if let report = made(fleet: read.entitlement.fleet, crashes: disk + batch, app: app) {
                failure = await ErrorReportsDay.deliver(report, day: day, at: stamp, in: defaults, stillOn: stillOn) {
                    try await calls.send($0, read.channel)
                }
                dayWent = day
            }
        }
        if day, !dayWent, offs == offsAtStart {
            // The day alone: on the hub's releases of this attempt, or the store's reading of this generation.
            if let known, let report = made(fleet: known.entitlement.fleet, crashes: [], app: app) {
                await ErrorReportsDay.deliver(report, day: true, at: stamp, in: defaults, stillOn: stillOn) {
                    try await calls.send($0, known.channel)
                }
            } else {
                ErrorReportsDay.tryAgain(at: stamp, in: defaults)   // no report could be made: in an hour
            }
        }
        guard offs == offsAtStart, crashes else { return }   // the switch went off while it was sent
        diskTriedAt = now()
        // A 200 takes out what went; 429, 5xx or no answer keep them for the next start; any other answer drops them.
        onDisk = ErrorReport.settle(batch, carriedKept: !disk.isEmpty, after: failure, in: file)
    }

    /// **The day while the hub does not answer** (Q5): on `answer`, to its channel, with the reach of the hub's last
    /// failed read.
    private func dayOnLastAnswer(_ answer: ErrorReportsDay.Answer, reach: ReachFacts.ReadKind, calls: Calls) async {
        let stamp = now(), offsAtStart = offs
        guard let report = made(fleet: answer.fleet, crashes: [],
                                app: health(releases: answer.releases, reach: reach, at: stamp, calls: calls)) else {
            return ErrorReportsDay.tryAgain(at: stamp, in: defaults)
        }
        await ErrorReportsDay.deliver(report, day: true, at: stamp, in: defaults, stillOn: { self.offs == offsAtStart }) {
            try await calls.send($0, answer.channel)
        }
    }

    /// A report of this build, or nil; a version that has no form of the contract is said once in a start.
    private func made(fleet: String?, crashes: [ErrorReport.Crash], app: AppHealth?) -> ErrorReport? {
        if version.map({ !ErrorReport.matches($0, ErrorReport.versionPattern) }) ?? true, !saidVersion {
            saidVersion = true
            Self.log.error("No error report goes: the version of this build has no form that our site takes.")
        }
        return ErrorReport(fleet: fleet, version: version, system: system, crashes: crashes, app: app)
    }

    /// **The Mac's day, from what the app knows now** (`AppHealth`): its update's reads and tries, the hub's reach and
    /// its last answer, the hub's releases, and the installs that stopped since the last report with the day that our
    /// site took.
    private func health(releases: AppHealth.HubReleases?, reach: ReachFacts.ReadKind, at now: Date,
                        calls: Calls) -> AppHealth {
        let sources = calls.sources()
        return AppHealth(
            update: AppHealth.update(sources.update, tries: AppUpdateTries.kept(in: defaults), running: sources.running,
                                     now: now),
            hub: AppHealth.hub(reach: reach, answered: ErrorReportsDay.hubAnswered(now: now, in: defaults),
                               releases: releases, now: now),
            installs: AppHealth.installs(sources.stops, since: ErrorReportsDay.installsSince(now: now, in: defaults)))
    }
}
#endif
