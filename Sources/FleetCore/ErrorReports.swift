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
    /// carry once a hub took his "Send" (`ErrorReportsDay.pressedOn`), and of those of a report with no hub (F5 piece
    /// 4), also when a "Don't send" and a new "Send" came between two passes of the sender.
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

    /// The fleet's sixteen hex characters (`Entitlement.fleet`), as Report a problem names it. nil only in the report
    /// of an install that stopped before this Mac has a hub (`noHub`): no fleet exists yet.
    public let fleet: String?
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

    /// **The report of an install that stopped before this Mac has a hub** (the F5 analysis of 22 November 2026, piece
    /// 4): no fleet's id, because no fleet exists yet, no crash, and the day whose hub's reach is `no_hub` with at least
    /// one install. Our site takes a report with no fleet only so (`from` "mac", `app`, no `crashes`), and keeps it in
    /// no row that is by fleet. nil for a version outside the contract, a day of another reach, or a day with no install.
    public static func noHub(version: String?, system: String?, app: AppHealth) -> ErrorReport? {
        guard let version, matches(version, versionPattern), app.hub.reach == AppHealth.noHubReach, !app.installs.isEmpty
        else { return nil }
        return ErrorReport(noFleet: version, system: system, app: app)
    }

    private init(noFleet version: String, system: String?, app: AppHealth) {
        fleet = nil
        from = "mac"
        self.version = version
        self.system = system.flatMap { Self.matches($0, Self.systemPattern) ? $0 : nil }
        crashes = []
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
    /// with no system has no `system`, a day with no crash has no `crashes`, a report of crashes has no `app`, and the
    /// report of an install with no hub (`noHub`) has no `fleet`.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if let fleet { try values.encode(fleet, forKey: .fleet) }
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

    /// **How long the Mac's day waits after a send that did not go** (the hub's rule, `errorreports.send`, with piece 3
    /// of F5): an hour after an answer that may change soon (`keeps`: no answer, a 429, a 5xx) and after a redirect
    /// that may end (302, 303, 307); a day after every other answer (a redirect that stays, 301 or 308, and every 4xx
    /// but 429, a 400 too, and a report too large), which the same report would only meet again. Each is a wait before
    /// the next try, never an end. The validator's finding 4.1 of piece 4: before this rule, such an answer to an early
    /// report held nothing, and the same install's stop asked for a new send at each pass of the loop.
    public static func dayWait(after error: Error) -> TimeInterval {
        if keeps(error) { return ErrorReportsDay.retry }
        if case ErrorReportError.refused(let status) = error, [302, 303, 307].contains(status) {
            return ErrorReportsDay.retry
        }
        return ErrorReportsDay.day
    }
}

// ---------------------------------------------------------------- from MetricKit's call stack tree

extension ErrorReport {
    /// **One crash, from the JSON of its MetricKit call stack tree** (`MXCallStackTree.jsonRepresentation()`) **and its
    /// numbers**: the signal, the exception's type and code, and the times of the payload that carried it: its begin
    /// (`begin`, MetricKit's `timeStampBegin`) as the entry's first time, and its end (`time`, `timeStampEnd`) as its
    /// last time. Whether a real payload's begin is at or before its crash is not known yet (`ErrorReportsSending`,
    /// "Open"); the crashes' floor reads the first time, so it fails closed when it is. A begin after the end counts
    /// as the end, and a begin before the contract's times as the contract's first time (September 2020), which no
    /// floor of a clock after that time passes. With no begin, both times are the end.
    ///
    /// The frames are those of the thread that the crash is attributed to (`threadAttributed`), from its root frame
    /// (the one that ran) down through each frame's `subFrames`, at most `maxFrames`. A frame whose `binaryUUID` is one
    /// of `own`, this app's own executable (the build that runs, and those that ran before it on this Mac), is that UUID
    /// and its `offsetIntoBinaryTextSegment`; every other frame is `"lib"`. The tree's other keys are never read: not
    /// `binaryName`, not `address`, nothing else.
    ///
    /// nil only for a time outside the contract's: a clock that is that wrong gives no time worth sending.
    public static func crash(stackTree json: Data, signal: Int?, type: Int?, code: Int?, from begin: Date? = nil,
                             at time: Date, own: Set<String>) -> Crash? {
        let seconds = time.timeIntervalSince1970
        guard seconds.isFinite, Double(times.lowerBound) <= seconds, seconds <= Double(times.upperBound) else { return nil }
        let when = Int(seconds)
        let start = begin.map { $0.timeIntervalSince1970 }.map { $0.isFinite ? $0 : -.infinity }
        let first = start.map { Int(max(Double(times.lowerBound), min($0, seconds))) } ?? when
        return Crash(signal: signal.flatMap { signals.contains($0) ? $0 : nil },
                     type: type.flatMap { types.contains($0) ? $0 : nil },
                     code: code.flatMap { codes.contains($0) ? $0 : nil },
                     frames: frames(of: json, own: Set(own.compactMap(uuid))), first: first, last: when)
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
                                 "blocked_by_app", "not_secure", "no_hub", "other"]
    /// **The reach of a Mac that no hub answered yet** (piece 4): the report of an install that stopped before a hub
    /// exists (`ErrorReport.noHub`). No read of the app gives it (`ReachFacts.ReadKind` has no such kind).
    public static let noHubReach = "no_hub"
    public static let installKinds = ["hub", "server", "mac", "other"]
    /// **The step that an install stopped at** (`ReachFacts.InstallStepName`, the ids of the two plans and a Mac's
    /// order), `none` for a stop before its first step, and `other`: what a diagnosis of the stop needs (the owner's note
    /// of 22 November 2026 to the picture of a stopped install: "it should report immediately and automatically! and try
    /// to auto diagnose"). A fixed name, never a line of a server.
    public static let installSteps = ["none", "read", "network", "code", "plan", "start", "wait_claim", "claim",
                                      "wait_ready", "verify", "join", "order", "other"]
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

    /// **Installs of one kind that stopped so, at one step**: how many, and the first and the last time, in whole
    /// seconds. Our site takes an entry with no `step` too (the Macs of W17 send none), and this Mac always sends it.
    public struct Install: Encodable, Equatable, Sendable {
        public let kind: String
        public let step: String
        public let stop: String
        public let cause: String
        public let count: Int
        public let first: Int
        public let last: Int

        public init(kind: String, step: String = "none", stop: String, cause: String, count: Int, first: Int, last: Int) {
            self.kind = AppHealth.word(kind, in: AppHealth.installKinds)
            self.step = AppHealth.word(step, in: AppHealth.installSteps)
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

    /// **The installs that stopped after `since`**: one entry for each kind, step, stop and cause, with how many and
    /// the first and the last time; the `mostInstalls` that stopped last.
    public static func installs(_ stops: [InstallStop], since: Date) -> [Install] {
        struct Key: Hashable { let kind, step, stop, cause: String }
        var found: [Key: (count: Int, first: Int, last: Int)] = [:]
        for stop in stops where stop.at > since {
            let seconds = stop.at.timeIntervalSince1970
            guard seconds.isFinite, Double(ErrorReport.times.lowerBound) <= seconds,
                  seconds <= Double(ErrorReport.times.upperBound) else { continue }
            let at = Int(seconds)
            let entry = Install(kind: stop.kind, step: stop.step, stop: stop.stop, cause: stop.cause, count: 1, first: at,
                                last: at)
            let key = Key(kind: entry.kind, step: entry.step, stop: entry.stop, cause: entry.cause)
            let before = found[key]
            found[key] = (min((before?.count ?? 0) + 1, ErrorReport.maxCount), min(before?.first ?? at, at),
                          max(before?.last ?? at, at))
        }
        return found.map { Install(kind: $0.key.kind, step: $0.key.step, stop: $0.key.stop, cause: $0.key.cause,
                                   count: $0.value.count, first: $0.value.first, last: $0.value.last) }
            .sorted { ($0.last, $0.kind, $0.step, $0.stop, $0.cause) > ($1.last, $1.kind, $1.step, $1.stop, $1.cause) }
            .prefix(mostInstalls).map { $0 }
    }
}

/// **One install that stopped**, by the fixed names of the app's records (`InstallRecord`): its kind as the contract
/// names it ("server" for a join), the step that it stopped at, its stop, its cause, and when it stopped.
public struct InstallStop: Equatable, Sendable {
    public let kind: String
    public let step: String
    public let stop: String
    public let cause: String
    public let at: Date

    public init(kind: String, step: String = "none", stop: String, cause: String, at: Date) {
        self.kind = kind
        self.step = step
        self.stop = stop
        self.cause = cause
        self.at = at
    }
}

#if os(macOS)
extension InstallStop {
    /// The stops in the app's kept records: a record that stopped, with its fixed names and its end, and the step that
    /// it stopped at as `setup_diagnosis` names it (`ReachFacts.installStep`). Never its hub, its host, its server's
    /// name, its id or its line (`says`).
    public static func of(_ records: [InstallRecord]) -> [InstallStop] {
        records.compactMap { record in
            guard record.outcome == .stopped, let stop = record.stop, let ended = record.ended else { return nil }
            let kind = switch record.kind {
            case .hub: "hub"
            case .join: "server"
            case .mac: "mac"
            }
            let step = record.stoppedAt.map { ReachFacts.installStep($0.rawValue).rawValue } ?? "none"
            return InstallStop(kind: kind, step: step, stop: stop.rawValue, cause: record.cause?.rawValue ?? "none",
                               at: ended)
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
///
/// **An install that stops asks for the day at once** (the F5 analysis of 22 November 2026, piece 4, and the owner's
/// note of that day to the picture of a stopped install: "it should report immediately and automatically!"): a stop
/// that no report of our site took yet makes the day go at the next pass, as an early report (`next`), at most
/// `earlyMost` in a day, as the hub's; each one that goes starts the day again. **Before a hub exists**, only while the
/// owner's "Send" of the first run waits for a hub (`FirstRunReports.waiting`), and no hub answered this Mac
/// (`noHubYet`), that stop goes in a report with no fleet's id (`ErrorReport.noHub`, `ErrorReportsSending`).
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
    /// The early reports in a `day` that an install that stopped may ask for, as the hub's (`errorreports.EARLY_MOST`).
    public static let earlyMost = 4
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

    /// Why a report goes now: the day is due, or an install that stopped asks for it early.
    public enum Due: Sendable {
        case day
        case early
    }

    /// What the hub said of the switch now: on (with its releases reading, when the sender has one), off (a hub that
    /// does not offer the switch is off too), or nothing.
    public enum Switch: Sendable {
        case on(ReleaseState?)
        case off
        case noAnswer
    }

    /// The day's times: the last day that went (or that our site refused for good), the next try after a failed one,
    /// the end of the block's wait, the last report with the block that our site took, the hub's last answer, the early
    /// reports that went, and what came of the last reports that carried an install that stopped.
    struct State: Codable, Equatable {
        var sent: Double?
        var retry: Double?
        var hold: Double?
        var taken: Double?
        var hub: Double?
        var earlies: [Double]?
        /// The last report that carried installs, whatever came of it, and the last ones that our site took
        /// (`keptTaken`).
        var installs: InstallsSent?
        var installsTaken: [InstallsSent]?
    }

    /// **One report that carried installs that stopped**: each entry that it carried (its kind, step, stop and cause,
    /// and its first and last time in whole seconds), the time of its send (its stamp), and what came of it.
    struct InstallsSent: Codable, Equatable {
        enum Outcome: String, Codable { case sent, waiting, refused }
        struct Entry: Codable, Equatable {
            var kind, step, stop, cause: String
            var first, last: Int
        }
        var entries: [Entry]
        var at: Double
        var outcome: Outcome

        init(_ installs: [AppHealth.Install], at: Double, outcome: Outcome) {
            entries = installs.map { Entry(kind: $0.kind, step: $0.step, stop: $0.stop, cause: $0.cause, first: $0.first,
                                           last: $0.last) }
            self.at = at
            self.outcome = outcome
        }

        /// **The report carried this stop** (the second reader's M1 of piece 4): an entry of its kind, step, stop and
        /// cause, by the words that an entry has, whose first and last time hold it. A stop that no block carried (one
        /// while the switch was off, one before the owner's "Send", one that the cut to `AppHealth.mostInstalls` left
        /// out) is in none, also when it is older than the newest stop of a block.
        func carried(_ stop: InstallStop) -> Bool {
            let seconds = stop.at.timeIntervalSince1970
            guard seconds.isFinite, Double(ErrorReport.times.lowerBound) <= seconds,
                  seconds <= Double(ErrorReport.times.upperBound) else { return false }
            let at = Int(seconds)
            let entry = AppHealth.Install(kind: stop.kind, step: stop.step, stop: stop.stop, cause: stop.cause, count: 1,
                                          first: at, last: at)
            return entries.contains {
                $0.kind == entry.kind && $0.step == entry.step && $0.stop == entry.stop && $0.cause == entry.cause
                    && $0.first <= at && at <= $0.last
            }
        }
    }

    /// **The entries of the reports with installs that our site took, that `installReport` reads**: as many as the app
    /// keeps install records (`KeptRecords` keeps 40), so that a stop of each record that the page can show reads
    /// `sent` for as long as its record is kept (the second reader's R2-N1). Each stop is in one entry of one report, so
    /// 40 entries hold the 40 newest stops at the least. The newest report stays whole.
    static let takenEntriesKept = 40

    /// The reports that our site took, newest first, cut to `takenEntriesKept` entries in all.
    static func keptTaken(_ reports: [InstallsSent]) -> [InstallsSent] {
        var kept: [InstallsSent] = [], entries = 0
        for report in reports {
            guard kept.isEmpty || entries + report.entries.count <= takenEntriesKept else { break }
            kept.append(report)
            entries += report.entries.count
        }
        return kept
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
        if waits(state, now: now) { return false }
        return valid(state.sent, now: now).map { at - $0 >= day } ?? true
    }

    /// A failed try waits for `retry`, or the block waits after a refusal.
    static func waits(_ state: State, now: Date) -> Bool {
        let at = now.timeIntervalSince1970
        if let retry = valid(state.retry, now: now), at < retry { return true }
        if let hold = valid(state.hold, now: now), at < hold { return true }
        return false
    }

    /// The early reports that went in the last `day`. One up to a `day` ahead of the clock stays counted, so that a
    /// clock that went back gives no more early reports (the hub's rule, `error_report_earlies`).
    static func earlies(_ state: State, now: Date) -> [Double] {
        let at = now.timeIntervalSince1970
        return (state.earlies ?? []).filter { $0.isFinite && at - $0 < day && $0 - at <= day }
    }

    /// **An early report may go now**: no failed try and no block wait, and fewer than `earlyMost` went in a `day`.
    public static func mayGoEarly(now: Date = Date(), in defaults: UserDefaults = AppDefaults.store) -> Bool {
        let state = state(in: defaults)
        return !waits(state, now: now) && earlies(state, now: now).count < earlyMost
    }

    /// **An install stopped that no report of our site took yet**: one of `stops` that ended after the installs' start
    /// (`installsSince`), and after `floor` when there is one, at most a `day` ahead of the clock.
    public static func asks(_ stops: [InstallStop], after floor: Date? = nil, now: Date = Date(),
                            in defaults: UserDefaults = AppDefaults.store) -> Bool {
        let since = max(installsSince(now: now, in: defaults), floor ?? .distantPast)
        return stops.contains { $0.at > since && $0.at.timeIntervalSince(now) <= day }
    }

    /// **Why a report goes now, or nil**: the day when it is due; else an early report when an install stopped that no
    /// report took yet (`asks`) and one may go (`mayGoEarly`). `stops` is read only when the day is not due.
    public static func next(stops: () -> [InstallStop], after floor: Date? = nil, now: Date = Date(),
                            in defaults: UserDefaults = AppDefaults.store) -> Due? {
        if due(now: now, in: defaults) { return .day }
        guard mayGoEarly(now: now, in: defaults), asks(stops(), after: floor, now: now, in: defaults) else { return nil }
        return .early
    }

    /// **No hub answered this Mac yet**: no answer of a hub is kept, and no answer of a switch from a hub. An answer
    /// "off" with no hub is the owner's own: a first-run "Don't send" (`FirstRunReports.choose`), which a later "Send"
    /// of the first run replaces (the second reader's M2 of piece 4), or a switch-off of this Mac. A kept answer that
    /// does not read counts as a hub's. "Start again" and a connect to another hub forget both (`forget`), so a Mac that
    /// left its fleet is as one that never had one.
    public static func noHubYet(in defaults: UserDefaults = AppDefaults.store) -> Bool {
        guard state(in: defaults).hub == nil else { return false }
        return defaults.object(forKey: answerKey) == nil || lastAnswer(in: defaults).map { $0.hub == nil } == true
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
        let floor = runStart(now: now, in: defaults)
        return Date(timeIntervalSince1970: max(base, floor ?? base))
    }

    /// **The start of the switch's run of answers "on"**, in seconds since 1970, never after `now`: the kept answer's
    /// `since` (his press when `pressedOn` set it, else this Mac's first read "on"), or its own time for an answer from
    /// before that field. nil when the kept answer is "off", or no answer is kept: no run, and nothing goes on it. The
    /// installs of a day (`installsSince`) and the crashes of an attempt, new and kept (`ErrorReportsSending`), start
    /// here, so the known limits of `installsSince` hold for a crash as for a stop: a run that starts before the true
    /// "on" (R2-N3), and a crash or a stop of while the switch was off, on a clock that ran ahead and was then put
    /// right, which carries a time after the run's start and can go.
    public static func runStart(now: Date = Date(), in defaults: UserDefaults = AppDefaults.store) -> Double? {
        lastAnswer(in: defaults).flatMap { $0.send ? min($0.since ?? $0.at, now.timeIntervalSince1970) : nil }
    }

    /// **The answer that the day goes on while the hub at `hub` does not answer**: the day is due, or an early report
    /// may go for an install that stopped (`early`, which `next` gave), the hub has been silent for `patience` or more of
    /// time awake (`silentFor`, on the uptime), and `take(.noAnswer)` gives an answer of that hub.
    public static func lastAnswer(hub: String, silentFor: TimeInterval?, now: Date = Date(), early: Bool = false,
                                  in defaults: UserDefaults = AppDefaults.store) -> Answer? {
        guard let silentFor, silentFor >= patience, early || due(now: now, in: defaults) else { return nil }
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
    /// the day's report (`day`): a 200 is the day's; a send that did not go waits `ErrorReportError.dayWait`: an hour
    /// is a `retry`, and a day is the day's and holds every report, the early ones too, for that day, as a 400 does, so
    /// that no answer of our site makes an install's stop ask again at the next pass (the validator's finding 4.1). An
    /// early report (`early`) that went counts in the day's `earlyMost`. What came
    /// of a block with installs is kept for the page of an install that stopped (`installReport`). It gives the error of
    /// the last send, or nil for a 200, for the crashes that the report carried (`ErrorReport.settle`).
    @discardableResult
    public static func deliver(_ report: ErrorReport, day isDay: Bool, early: Bool = false, at stamp: Date = Date(),
                               in defaults: UserDefaults = AppDefaults.store,
                               isolation: isolated (any Actor)? = #isolation, stillOn: () -> Bool = { true },
                               send: (ErrorReport) async throws -> Void) async -> Error? {
        var report = report
        var failure: Error?
        let at = stamp.timeIntervalSince1970
        let carried = report.app.flatMap { $0.installs.isEmpty ? nil : $0.installs }
        while true {
            do { try await send(report); failure = nil } catch { failure = error }
            guard report.app != nil, case .refused(400)? = failure as? ErrorReportError else { break }
            var state = state(in: defaults)
            state.hold = at + day
            if let carried { state.installs = InstallsSent(carried, at: at, outcome: .refused) }
            save(state, in: defaults)
            guard stillOn() else { return failure }
            guard !report.crashes.isEmpty else { break }
            report = report.withoutApp
        }
        var state = state(in: defaults)
        if failure == nil, report.app != nil { state.taken = at }
        if let carried, report.app != nil {
            // The block was in the last send: what came of it is what came of its installs.
            let outcome: InstallsSent.Outcome = failure.map {
                ErrorReportError.dayWait(after: $0) < day ? .waiting : .refused
            } ?? .sent
            let sent = InstallsSent(carried, at: at, outcome: outcome)
            state.installs = sent
            if outcome == .sent { state.installsTaken = keptTaken([sent] + (state.installsTaken ?? [])) }
        }
        if early, failure == nil {
            state.earlies = earlies(state, now: stamp) + [at]
        }
        if isDay {
            let wait = failure.map(ErrorReportError.dayWait(after:))
            if let wait, wait < day {
                state.retry = at + wait
            } else {
                state.sent = at
                state.retry = nil
                if let wait { state.hold = max(valid(state.hold, now: stamp) ?? 0, at + wait) }
            }
        }
        save(state, in: defaults)
        return failure
    }

    /// **What came of the report of the install that stopped so** (the page of an install that stopped reads it, with
    /// `InstallStop.of` of its record; the F5 analysis, piece 4): `sent` with the time of the send when a report that our
    /// site took carried it (an entry of its kind, step, stop and cause whose times hold it), for as long as the app keeps
    /// its record (`takenEntriesKept`); `refused` when our site refused the last report that carried it (an answer of
    /// `ErrorReportError.dayWait` a day: it goes again a day later); `waiting` while it goes, or goes again, at a later
    /// pass (no answer, a 5xx, a 429, a 302, 303 or 307, the day's early reports used, the switch not read yet), also a
    /// stop of the first run after the owner's "Send", while that "Send" waits for the end of the first run; `notSent`
    /// while nothing lets it go (the switch is off, a first-run "no" waits, no answer of the owner at all), for a stop
    /// from before the run of answers "on" (`installsSince`) or from before the owner's latest "Send", and for a stop
    /// that the reports left out. A report that our site took stays `sent` after a switch-off. **`waiting` is not sure**
    /// for a stop in the seconds between a press of "Send" and the sender's next pass, for a stop of a first run that
    /// never ends, and for a build whose version has no form of the contract, which sends nothing.
    public static func installReport(of stop: InstallStop, now: Date = Date(),
                                     in defaults: UserDefaults = AppDefaults.store) -> InstallReportState {
        let state = state(in: defaults)
        if let taken = (state.installsTaken ?? []).first(where: { valid($0.at, now: now) != nil && $0.carried(stop) }) {
            return .sent(Date(timeIntervalSince1970: taken.at))
        }
        let firstRun = FirstRunReports.waiting(in: defaults)
        // The owner's "Send" of the first run lets each stop after his latest press go: in a report with no hub while no
        // hub answered this Mac, and once his hub took the "Send", in the fleet's report, from that press on
        // (`pressedOn`, the second reader's R2-M1). Else the switch's kept answer decides, with its run (`installsSince`).
        let press = FirstRunReports.pressed(in: defaults).flatMap { valid($0.timeIntervalSince1970, now: now) }
        let firstRunSend = firstRun == true && press.map { stop.at.timeIntervalSince1970 > $0 } != false
        let consent = firstRunSend || (firstRun != false && lastAnswer(in: defaults)?.send == true)
        guard consent, stop.at > installsSince(now: now, in: defaults) else { return .notSent }
        if let last = state.installs, last.carried(stop), last.outcome == .refused { return .refused }
        return .waiting
    }
}

/// **What came of the report of an install that stopped** (`ErrorReportsDay.installReport`), for the page of that
/// install, which shows no word of it unless the owner approved that word.
public enum InstallReportState: Equatable, Sendable {
    /// Our site took the report that carried it (a 200), at this time of this Mac: the send's own time.
    case sent(Date)
    /// It goes, or goes again, at a later pass: no answer, a 5xx, a 429, a 302, 303 or 307, or the day's early reports
    /// are used.
    case waiting
    /// Nothing lets it go: the switch is off, a first-run "no" waits, or the owner gave no answer at all.
    case notSent
    /// Our site refused the last report that carried it (a 4xx but 429, a 301 or 308): it goes again a day later.
    case refused
}

#if os(macOS)
// ---------------------------------------------------------------- the sender's rules

/// **The rules of the Mac's sends to our own site** (the app's `ErrorReportsSender` gives it the store's facts at each
/// tick, and the calls to the hub and to our site; this type decides). **The crashes go only while the owner's switch is
/// on, at that moment, and only a crash from after its run of "on" began** (`ErrorReportsDay.runStart`, the floor of the
/// installs too): MetricKit gives a crash at a later start, up to about a day after it, so a crash from while the
/// switch was off, or from before his first "on", comes after the "on" with its own older time, and is dropped then;
/// so is a kept crash of an earlier run, and the kept file loses it.
/// Before each send it asks the hub (`GET /ui/error-reports`); off, or a hub with no switch, drops
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
/// while the owner's answer of the first run's page, "no", waits for a hub (`FirstRunReports.waiting`), and no crash
/// goes on the hub's "on" then either: they wait in memory, and the hub is asked again a minute later.
///
/// **An install that stops makes the day go at the next pass** (`ErrorReportsDay.next`, at most four early reports a
/// day). **Before a hub exists** (the F5 analysis of 22 November 2026, piece 4): while the owner's "Send" of the first
/// run's page waits for a hub and no hub answered this Mac (`ErrorReportsDay.noHubYet`), an install that stopped after
/// this sender saw that "Send" goes in one report with no fleet's id (`ErrorReport.noHub`), to our own site, with the
/// reach `no_hub`, and never a crash. "Don't send", no answer, Back to the welcome page and a new start of the app end
/// that wait (`FirstRunReports`), and with it every such report; both are read again just before the send.
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
    /// **Since when this sender saw the owner's "Send" of a first run** that no hub took yet, in memory only: no install
    /// that stopped before it goes in a report with no hub, and a new start of the app sees it anew. nil while none waits.
    private var yesSince: Date?

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
        let firstRun = FirstRunReports.waiting(in: defaults)
        yesSince = firstRun == true ? yesSince ?? now : nil
        if onDisk == nil {
            onDisk = ErrorReport.kept(file)
            if onDisk?.isEmpty == true { ErrorReport.forget(file) }   // a file that holds no crash is no file
        }
        // The day: due, or an install that stopped asks for it early; and no "no" of the owner's first run waits for a hub.
        let due = firstRun == false ? nil : ErrorReportsDay.next(stops: { calls.sources().stops }, now: now, in: defaults)
        let day = due != nil
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
            // No hub answered this Mac yet, and the owner's "Send" of this first run waits for one: only the report of
            // an install that stopped after that "Send" goes, with no fleet's id (piece 4).
            if let seen = yesSince, ErrorReportsDay.noHubYet(in: defaults) {
                let yes = Self.latestSend(seen, now: now, in: defaults)
                let stops = calls.sources().stops
                guard ErrorReportsDay.asks(stops, after: yes, now: now, in: defaults),
                      let due = ErrorReportsDay.next(stops: { stops }, after: yes, now: now, in: defaults)
                else { return nil }
                return run { await self.withNoHub(since: yes, early: due == .early, calls: calls) }
            }
            // The hub does not answer: only the day goes, on the switch's last answer of this hub (Q5).
            guard let due, let answer = ErrorReportsDay.lastAnswer(hub: tick.hub, silentFor: silentSince.map { uptime() - $0 },
                                                                   now: now, early: due == .early, in: defaults)
            else { return nil }
            return run { await self.dayOnLastAnswer(answer, reach: tick.reach, early: due == .early, calls: calls) }
        }
        guard !fresh.isEmpty || !disk.isEmpty || look || switchLook || (day && !switchOff) else { return nil }
        let batch = fresh
        if disk.isEmpty && batch.isEmpty { lastLook = now }
        lastSwitchLook = now
        fresh = []
        return run { await self.attempt(batch, disk: disk, hub: tick.hub, offered: tick.offered, day: due, calls: calls) }
    }

    private func run(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        working = true
        return Task { @MainActor in
            await body()
            self.working = false
        }
    }

    /// The hub answers: the switch is read now, and only its answer lets anything go.
    private func attempt(_ batch: [ErrorReport.Crash], disk: [ErrorReport.Crash], hub: String, offered: Bool,
                         day due: ErrorReportsDay.Due?, calls: Calls) async {
        let offsAtStart = offs
        var day = due != nil
        let early = due == .early
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
        var crashes = !(batch.isEmpty && disk.isEmpty)
        var read: ReleaseState?
        if crashes || day { read = await calls.readReleases() }
        guard offs == offsAtStart else { return }
        // While the owner's "no" of a first run waits for this hub, also one that he gave during these reads, the hub's
        // "on" is kept as no answer, and nothing goes on it (the validator's finding 1 of pieces 1 and 5): no day, and
        // no crash. With no run, no crash goes and the kept file goes, as at `off()` (main's crash floor): the crashes
        // of this attempt are dropped, not put back (the second reader's R4-N1), and the kept file is removed, whether
        // this attempt carried it or not (the F5 validator's N4). The "no" keeps the switch's answer "off", so the next
        // "on" starts a new run after each of them, and the crash floor would cut them anyway. Kept, they only made the
        // hub be read: the crashes in memory each minute of the wait, the kept file at each pass of the loop (R5-M1)
        // and then at its minute's look. With nothing in memory and no file, no pass reads the hub for them.
        if FirstRunReports.waiting(in: defaults) == false {
            onDisk = []
            ErrorReport.forget(file)
            return
        }
        // The kept answer has the fleet's id and channel of the hub's releases: its own read, or the store's reading.
        let known = read ?? calls.storeReleases()
        ErrorReportsDay.take(.on(known), hub: hub, now: now(), in: defaults)
        // **A crash goes only when it came after the start of the switch's run of "on"** (the crashes' floor, as the
        // installs' one), a new one and a kept one alike: one from while the switch was off, from before his first "on"
        // or from an earlier run (kept under another hub, or before a first-run "Don't send", "Start again", or by a
        // build before this floor) is dropped, never written to the disk, and the kept file loses it at once. With no
        // run, no crash goes and the kept file goes, as at `off()`; a first-run "no" that waits ends the attempt above,
        // before this, and its crashes and the kept file go there, as at `off()`. Inside one run its start only moves
        // earlier (`take(.on)`, `pressedOn`), so each crash kept in this run
        // stays (the second reader's C1). The time compared is the crash's first time, the begin of the payload that
        // carried it (MetricKit's `timeStampBegin`; its last time is the payload's end), so it fails closed when the
        // begin is at or before the crash: a payload that begins before the "on" and ends after it does not go.
        // **Open** (the validator's C.2): the times of a real payload of this app are not known. A live check got none
        // (MetricKit refused an ad-hoc signed test bundle in a temporary folder, and this Mac's "Share with app
        // developers" is off). So a payload with one time that the system wrote after the "on", for a crash before it,
        // still passes.
        //
        // **A known limit** (C-N2): a crash of the first run after the owner's "Send" is dropped when the sender reads
        // the hub's default "off" before the hub took that "Send" (`off()` empties what waits). The installs have
        // `pressedOn` for that time; the crashes have nothing like it. **And one at the update from 0.1.453:** a file
        // that it kept passed no floor, and its answer's own time stands for the run's start, so the kept crashes from
        // before that time go in no report, once. Both fail closed. **Three more small losses**, which fail closed too:
        // two equal crashes merge by the earlier time, so an entry with one crash before the start is dropped whole; a
        // new address of the same hub starts a new run, and the cut takes that fleet's kept crashes; and a late "off"
        // over a press starts the run at the next look, and the cut takes the kept crashes of the run before. And the
        // begin rule drops a true crash after the "on" when its payload began before the "on".
        let start = ErrorReportsDay.runStart(now: now(), in: defaults)
        let inRun = start.map { start in batch.filter { Double($0.first) >= start } } ?? []
        let keptInRun = start.map { start in disk.filter { Double($0.first) >= start } } ?? []
        if keptInRun.count != disk.count {
            // The cut took an entry: the file keeps only what stays.
            if keptInRun.isEmpty { ErrorReport.forget(file) } else { try? ErrorReport.keep(keptInRun, in: file) }
            onDisk = ErrorReport.kept(file)
        }
        crashes = !(inRun.isEmpty && keptInRun.isEmpty)
        // An early report goes only for a stop that this run of answers "on" lets go (`installsSince`): a stop of while
        // the switch was off asked for it before the read, and asks for none now.
        if early, !ErrorReportsDay.asks(calls.sources().stops, now: now(), in: defaults) { day = false }
        guard crashes || day else { return }   // only a look at the switch: the file was tried at this start
        let stamp = now()
        // The hub answered the switch now: its reach is "none" in this day, whatever an earlier read gave.
        let app = day ? health(releases: known.map(AppHealth.HubReleases.init), reach: .none, at: stamp, calls: calls) : nil
        let stillOn = { self.offs == offsAtStart }
        // The crashes go as before W17: with the hub's own releases read of this attempt, or not at all (they wait).
        var failure: Error? = ErrorReportError.unready
        var dayWent = false
        if crashes, let read {
            if let report = made(fleet: read.entitlement.fleet, crashes: keptInRun + inRun, app: app) {
                // A report of crashes alone uses none of the day's early reports (the second reader's R2-N4).
                failure = await ErrorReportsDay.deliver(report, day: day, early: early && day, at: stamp, in: defaults,
                                                        stillOn: stillOn) {
                    try await calls.send($0, read.channel)
                }
                dayWent = day
            }
        }
        if day, !dayWent, offs == offsAtStart {
            // The day alone: on the hub's releases of this attempt, or the store's reading of this generation.
            if let known, let report = made(fleet: known.entitlement.fleet, crashes: [], app: app) {
                await ErrorReportsDay.deliver(report, day: true, early: early, at: stamp, in: defaults, stillOn: stillOn) {
                    try await calls.send($0, known.channel)
                }
            } else {
                ErrorReportsDay.tryAgain(at: stamp, in: defaults)   // no report could be made: in an hour
            }
        }
        guard offs == offsAtStart, crashes else { return }   // the switch went off while it was sent
        diskTriedAt = now()
        // A 200 takes out what went; 429, 5xx or no answer keep them for the next start; any other answer drops them.
        onDisk = ErrorReport.settle(inRun, carriedKept: !keptInRun.isEmpty, after: failure, in: file)
    }

    /// **The day while the hub does not answer** (Q5): on `answer`, to its channel, with the reach of the hub's last
    /// failed read.
    private func dayOnLastAnswer(_ answer: ErrorReportsDay.Answer, reach: ReachFacts.ReadKind, early: Bool,
                                 calls: Calls) async {
        let stamp = now(), offsAtStart = offs
        guard let report = made(fleet: answer.fleet, crashes: [],
                                app: health(releases: answer.releases, reach: reach, at: stamp, calls: calls)) else {
            return ErrorReportsDay.tryAgain(at: stamp, in: defaults)
        }
        await ErrorReportsDay.deliver(report, day: true, early: early, at: stamp, in: defaults,
                                      stillOn: { self.offs == offsAtStart }) {
            try await calls.send($0, answer.channel)
        }
    }

    /// **The start of the stops that a report with no hub carries**: the first pass that saw the owner's "Send" waiting
    /// (`seen`), and his latest press of a card when it is later (a "Don't send" and a new "Send" between two passes),
    /// never after `now`. A press kept while the clock was more than a day ahead counts as none.
    static func latestSend(_ seen: Date, now: Date, in defaults: UserDefaults) -> Date {
        let pressed = FirstRunReports.pressed(in: defaults).flatMap { ErrorReportsDay.valid($0.timeIntervalSince1970, now: now) }
        return max(seen, pressed.map { Date(timeIntervalSince1970: min($0, now.timeIntervalSince1970)) } ?? seen)
    }

    /// **The report of an install that stopped before a hub exists** (piece 4): to our own site (no channel: no hub
    /// named one), with no fleet's id and no crash, the reach `no_hub`, and only the installs that stopped after the
    /// owner's latest "Send" (`since`, `latestSend`). The "Send" that waits, and that no hub answered this Mac, are read
    /// again just before the send, and so is the time of his latest press.
    private func withNoHub(since seen: Date, early: Bool, calls: Calls) async {
        let stamp = now(), offsAtStart = offs
        let stillYes = {
            self.offs == offsAtStart && FirstRunReports.waiting(in: self.defaults) == true
                && ErrorReportsDay.noHubYet(in: self.defaults)
        }
        guard stillYes() else { return }
        let sources = calls.sources()
        let since = max(ErrorReportsDay.installsSince(now: stamp, in: defaults), Self.latestSend(seen, now: stamp, in: defaults))
        let app = AppHealth(
            update: AppHealth.update(sources.update, tries: AppUpdateTries.kept(in: defaults), running: sources.running,
                                     now: stamp),
            hub: AppHealth.Hub(reach: AppHealth.noHubReach, hours: 0, runs: nil, newest: nil, missing: 0),
            installs: AppHealth.installs(sources.stops, since: since))
        guard let report = made(fleet: nil, crashes: [], app: app, noHub: true) else {
            return ErrorReportsDay.tryAgain(at: stamp, in: defaults)
        }
        await ErrorReportsDay.deliver(report, day: true, early: early, at: stamp, in: defaults, stillOn: stillYes) {
            try await calls.send($0, nil)
        }
    }

    /// A report of this build, or nil; a version that has no form of the contract is said once in a start. `noHub`:
    /// the report of an install with no hub (`ErrorReport.noHub`), with no fleet's id.
    private func made(fleet: String?, crashes: [ErrorReport.Crash], app: AppHealth?, noHub: Bool = false) -> ErrorReport? {
        if version.map({ !ErrorReport.matches($0, ErrorReport.versionPattern) }) ?? true, !saidVersion {
            saidVersion = true
            Self.log.error("No error report goes: the version of this build has no form that our site takes.")
        }
        if noHub { return app.flatMap { ErrorReport.noHub(version: version, system: system, app: $0) } }
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
