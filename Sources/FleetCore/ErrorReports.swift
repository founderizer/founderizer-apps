import Foundation
#if os(macOS)
import MachO
#endif

// ---------------------------------------------------------------- the switch

/// **Error reports** (the owner's "Yes, as drawn" of 16 November 2026, to the picture `P3-error-reports-switch.png`):
/// Settings › General › Error reports › Send to Founderizer's developers. It is off until the owner turns it on, and
/// only that switch turns it on. While it is on, the crashes of this app that MetricKit gives it go to our own site as
/// codes and counts (`ErrorReport`): no text of a crash, no work, no name and no key.
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
    static let versionPattern = #"\A[0-9A-Za-z .()+_-]{1,40}\z"#
    static let systemPattern = #"\A[0-9A-Za-z .()+_-]{0,40}\z"#
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

    /// The report, or nil when it cannot be sent: no fleet id or version of the contract's shape, or no crash that is
    /// one. Identical crashes are one entry, and at most `maxCrashes` go: the ones seen last.
    public init?(fleet: String?, version: String?, system: String?, crashes: [Crash]) {
        guard let fleet, Self.matches(fleet, Self.fleetPattern), let version, Self.matches(version, Self.versionPattern)
        else { return nil }
        let crashes = Self.merged(crashes.compactMap(\.checked))
        guard !crashes.isEmpty else { return nil }
        self.fleet = fleet
        self.from = "mac"
        self.version = version
        self.system = system.flatMap { Self.matches($0, Self.systemPattern) ? $0 : nil }
        self.crashes = crashes
    }

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

    private enum CodingKeys: String, CodingKey { case fleet, from, version, system, crashes }

    /// **An optional key of the report is left out, never `null`**: the site refuses a null key at the top, so a report
    /// with no system has no `system`.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(fleet, forKey: .fleet)
        try values.encode(from, forKey: .from)
        try values.encode(version, forKey: .version)
        if let system { try values.encode(system, forKey: .system) }
        try values.encode(crashes, forKey: .crashes)
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
        return URL(string: spanish ? "https://founderizer.com/es/privacy#error-reports"
                                   : "https://founderizer.com/privacy#error-reports")!
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
    /// is off, or before the hub has said that it is on, is never on the disk.
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
    public static func kept(_ file: URL = keptFile) -> [Crash] {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber,
              size.intValue <= 2 * maxBytes, let data = try? Data(contentsOf: file),
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

    public static func forget(_ file: URL = keptFile) {
        try? FileManager.default.removeItem(at: file)
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
