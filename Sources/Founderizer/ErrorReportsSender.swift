import FleetCore
import Foundation
import MetricKit

/// **This app's crashes, as MetricKit gives them at a start**, made into the entries of an error report at once
/// (`ErrorReport.crash`): the signal, the exception's type and code, and the frames of the crashed thread as UUIDs and
/// offsets. No text of a crash is read: not its termination reason, not its exception reason, not its memory region
/// text, not a binary's name. Registered once, when the app has finished launching (`FleetAppDelegate`).
final class CrashSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = CrashSubscriber()
    /// The UUIDs of this app's own executable: the build that runs, and the builds that ran before it on this Mac,
    /// whose crashes this start can still get.
    private let own: Set<String>
    private static let imagesKey = "errorReportImages"

    private override init() {
        let images = ErrorReport.ownImages(running: ErrorReport.runningImage,
                                           kept: UserDefaults.standard.stringArray(forKey: Self.imagesKey) ?? [])
        own = Set(images)
        super.init()
    }

    /// Adds the running build to the list of this app's builds: called only after the hub has said that the switch is on.
    static func remember() {
        let images = ErrorReport.ownImages(running: ErrorReport.runningImage,
                                           kept: UserDefaults.standard.stringArray(forKey: imagesKey) ?? [])
        UserDefaults.standard.set(images, forKey: imagesKey)
    }

    @MainActor private static var started = false

    /// Once in a run of the app; a second call does nothing.
    @MainActor static func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(shared)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var crashes: [ErrorReport.Crash] = []
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let code = crash.exceptionCode.map { Int(truncatingIfNeeded: $0.int64Value) }
                if let entry = ErrorReport.crash(stackTree: crash.callStackTree.jsonRepresentation(),
                                                 signal: crash.signal?.intValue, type: crash.exceptionType?.intValue,
                                                 code: code, at: payload.timeStampEnd, own: own) {
                    crashes.append(entry)
                }
            }
        }
        guard !crashes.isEmpty else { return }
        Task { @MainActor in ErrorReportsSender.shared.take(crashes) }
    }
}

/// **The crashes go to our own site only while the owner's switch is on, at that moment.** Before each send it asks
/// the hub (`GET /ui/error-reports`): off, or a hub with no switch, drops them, and nothing of them is kept; on, they
/// go to `<channel>/api/errors` with the fleet's id and the channel of `GET /ui/releases`, as Report a problem names
/// them. A send that can still go (our site's 429 or 5xx, or no answer) keeps them in one small file
/// (`ErrorReport.keptFile`, at most 20 entries), which the next start tries once and deletes after a 200, and which goes
/// as soon as the switch is found off. Any other answer of the site (400, another 4xx) drops them and the file: the site
/// will never take that payload (`ErrorReport.settle`).
///
/// It works under the hood, from the store's own loop (`tick`), and only while something waits: with no crash it asks
/// nothing. A crash that came before the hub answered waits in memory; the disk holds none that the hub did not first
/// say may go.
@MainActor final class ErrorReportsSender {
    static let shared = ErrorReportsSender()
    /// The crashes of this run that wait for the hub's answer: in memory only.
    private var fresh: [ErrorReport.Crash] = []
    /// What the file holds, read at the first tick of this start.
    private var onDisk: [ErrorReport.Crash]?
    /// The file was tried at this start: what failed waits for the next start.
    private var diskTried = false
    private var working = false
    /// Each time the switch was found off: an attempt on its way then keeps nothing.
    private var offs = 0
    /// No attempt before this moment, after a hub that did not answer the switch's read.
    private var notBefore: Date?
    /// The last time the switch was read for a kept file alone (nothing else waiting).
    private var lastLook: Date?
    private let file = ErrorReport.keptFile

    func take(_ crashes: [ErrorReport.Crash]) { fresh = ErrorReport.merged(fresh + crashes) }

    /// The switch is off: nothing waits, and the file is gone.
    func off() {
        offs += 1
        fresh = []
        onDisk = []
        ErrorReport.forget(file)
    }

    func tick(store: FleetStore) {
        if onDisk == nil {
            onDisk = ErrorReport.kept(file)
            if onDisk?.isEmpty == true { ErrorReport.forget(file) }   // a file that holds no crash is no file
        }
        let disk = diskTried ? [] : onDisk ?? []
        // A file kept after a failed send: the switch is read again each minute, so that a switch-off deletes it.
        let look = diskTried && fresh.isEmpty && onDisk?.isEmpty == false && lastLook.map { Date().timeIntervalSince($0) >= 60 } ?? true
        guard !working, !(fresh.isEmpty && disk.isEmpty && !look), notBefore.map({ Date() >= $0 }) ?? true,
              store.isFresh, let database = store.state?.db else { return }
        let offered = store.state?.ui_features?.contains(ErrorReportsState.feature) == true
        let batch = fresh, hub = store.hub
        if disk.isEmpty && batch.isEmpty { lastLook = Date() }
        fresh = []
        working = true
        Task {
            await attempt(batch, disk: disk, hub: hub, database: database, offered: offered)
            working = false
        }
    }

    private func attempt(_ batch: [ErrorReport.Crash], disk: [ErrorReport.Crash], hub: URL, database: String,
                         offered: Bool) async {
        let offsAtStart = offs
        guard offered else { return off() }         // a hub with no switch: it is off
        let on: Bool
        do { on = try await HubClient().errorReports(hub: hub, database: database).send } catch {
            // The switch did not answer: they wait in memory, and the next try is a minute away.
            fresh = ErrorReport.merged(batch + fresh)
            notBefore = Date().addingTimeInterval(60)
            return
        }
        guard offs == offsAtStart else { return }
        guard on else { return off() }
        CrashSubscriber.remember()
        if batch.isEmpty && disk.isEmpty { return }   // only a look at the switch: the file was tried at this start
        let releases = try? await HubClient().releases(hub: hub, database: database)
        var failure: Error? = ErrorReportError.unready
        if let releases, let report = ErrorReport(fleet: releases.entitlement.fleet,
                                                   version: ErrorReport.version(of: AppVersion.running),
                                                   system: ErrorReport.runningSystem, crashes: disk + batch) {
            do {
                try await ErrorReportClient().send(report, channel: releases.channel)
                failure = nil
            } catch { failure = error }
        }
        guard offs == offsAtStart else { return }   // the switch went off while it was sent
        diskTried = true
        // A 200 takes out what went; 429, 5xx or no answer keep them for the next start; any other answer drops them.
        onDisk = ErrorReport.settle(batch, carriedKept: !disk.isEmpty, after: failure, in: file)
    }
}
