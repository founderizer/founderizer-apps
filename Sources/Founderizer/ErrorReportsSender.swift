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
                                           kept: AppDefaults.store.stringArray(forKey: Self.imagesKey) ?? [])
        own = Set(images)
        super.init()
    }

    /// Adds the running build to the list of this app's builds: called only after the hub has said that the switch is on.
    static func remember() {
        let images = ErrorReport.ownImages(running: ErrorReport.runningImage,
                                           kept: AppDefaults.store.stringArray(forKey: imagesKey) ?? [])
        AppDefaults.store.set(images, forKey: imagesKey)
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
                                                 code: code, from: payload.timeStampBegin, at: payload.timeStampEnd,
                                                 own: own) {
                    crashes.append(entry)
                }
            }
        }
        guard !crashes.isEmpty else { return }
        Task { @MainActor in ErrorReportsSender.shared.take(crashes) }
    }
}

/// **The app's side of the error reports** (`ErrorReportsSending`, in FleetCore, holds every rule and its tests): at
/// each tick of the store's loop it gives the store's facts and the calls to the hub and to our own site. The crashes go
/// only while the owner's switch is on, at that moment, and the Mac's day once a day (W17). It works under the hood,
/// with nothing on a page.
@MainActor final class ErrorReportsSender {
    static let shared = ErrorReportsSender()
    private let sending = ErrorReportsSending(file: ErrorReport.keptFile, version: ErrorReport.version(of: AppVersion.running),
                                              system: ErrorReport.runningSystem, remember: { CrashSubscriber.remember() })

    func take(_ crashes: [ErrorReport.Crash]) { sending.take(crashes) }

    /// The switch is off (`ErrorReportsSending.off`).
    func off() { sending.off() }

    func tick(store: FleetStore) {
        let hub = store.hub
        let database = store.isFresh ? store.state?.db : nil
        let tick = ErrorReportsSending.Tick(
            hub: hub.absoluteString, database: database,
            offered: store.state?.ui_features?.contains(ErrorReportsState.feature) == true,
            answered: store.lastSuccess, reach: ReachFacts.readKind(store.lastReadError))
        let calls = ErrorReportsSending.Calls(
            readSwitch: { try await HubClient().errorReports(hub: hub, database: database ?? "").send },
            readReleases: { try? await HubClient().releases(hub: hub, database: database ?? "") },
            storeReleases: { [weak store] in
                guard let store, let database else { return nil }
                return store.reading("releases") ?? store.keptReleases.reading(of: database)
            },
            sources: { [weak store] in
                ErrorReportsSending.Sources(update: store?.updates.facts ?? AppUpdateFacts(), running: AppVersion.running,
                                            stops: InstallStop.of(InstallRecords.shared.all()))
            },
            send: { try await ErrorReportClient().send($0, channel: $1) })
        sending.tick(tick, calls: calls)
    }
}
