import AppKit
import FleetCore
import Observation
import SwiftUI
import notify

/// **Founderizer updates itself, without a press** (the owner, 22 October 2026: "do they get the latest updates,
/// improvements and bug fixes automatically? it must be like that!").
///
/// The fleet's own poll calls `tick` every few seconds, as it calls the copy keeper's. It reads the channel at the
/// start and every five minutes, one minute after a read that failed, when the owner comes back to the app, and at
/// once after the signal of a new build that the Mac that publishes the app posts (`AppUpdatePolicy`), and only while
/// the fleet's Automatic updates switch is on: one switch for the fleet and the Mac
/// that drives it. A read that fails changes nothing it knew: the build that waits still waits. An
/// offered build is put in place exactly as the sidebar's Update puts it — downloaded, checked against the signed manifest
/// and against Apple's signature of the running app, swapped — and the app then starts again, but only after the owner
/// has been away from it for two minutes with no request of his on its way (`AppUpdatePolicy`). Only a Developer ID
/// build updates itself: a development build made on this Mac is never swapped for a published one.
///
/// **Before any hub answered this Mac** (the first run; the owner's yes of 14 November 2026) it reads our channel as a
/// Mac that has just downloaded the app does, and a build goes in only while the setup's first page shows with no
/// install begun; from the claim of an install until he leaves the setup, none goes in (`AppUpdatePolicy.setupHolds`).
@MainActor @Observable
final class AppAutoUpdate {
    /// The build that installs itself the next time he is away from the app, or nil.
    private(set) var waiting: AppManifest?
    /// Why the last attempt stopped, for Settings › General › Updates. The next read tries again.
    private(set) var failure: String?
    /// The last read that reached the channel.
    private(set) var known: AppUpdateReading?
    /// Since when every read has failed, or nil while they reach the channel; General says so only after long.
    private(set) var failingSince: Date?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var askedAt: Date?
    @ObservationIgnored private var awaySince: Date?
    /// **He came back to the app since the last read began** (`AppUpdatePolicy.back`; the owner, 16 November 2026: "I
    /// always have to go to the topbar to check for updates!"): the next read comes at once, so the sidebar's Update
    /// stands for a build that came while he was away.
    @ObservationIgnored private var cameBack = false
    /// **A signal of a new build came since the last read began** (`AppUpdatePolicy.signal`): the Mac that publishes
    /// the app posts it when a build has ended, and the next read comes at once, so the sidebar's Update stands within
    /// seconds of the build. Registered once, at `start`.
    @ObservationIgnored private var signalled = false
    @ObservationIgnored private var listens = false
    @ObservationIgnored private var signalToken: Int32 = 0
    @ObservationIgnored private var automatic = false
    @ObservationIgnored private var working = false
    @ObservationIgnored private let running = AppVersion.running
    @ObservationIgnored private let installer = AppUpdateInstaller()
    /// **The build that waited when the app last quit** (`WaitingBuild`, kept with the fleet's reading; review B, round 3
    /// of 30 October 2026): the Update row draws from it in the launch's first frame, while it is newer than the build
    /// that runs, until this launch's own read decides what waits. **A read that fails takes it away** (`KeptReading`,
    /// as the kept health and releases; review B, round 5): the Updates page that the row opened drew only this
    /// launch's reading (`known`), so the row stood for a build that the page did not show.
    private(set) var keptWaiting = KeptReading<WaitingBuild>()
    /// **The setup's first page shows, and no install of it began** (`FirstRunView`, `AppUpdatePolicy.setupHolds`): before
    /// any hub answered, the only time a build goes in by itself.
    @ObservationIgnored var setupAtRest = false
    /// The last read was made before any hub answered: our channel, with no fleet and no switch of a fleet.
    @ObservationIgnored private var readBeforeHub = false
    /// **Each read of our channel, for the day's error report** (W17, `AppHealth.update`): what the last one that reached
    /// it said, and since when reads fail. A failed install is kept apart, with its build (`AppUpdateTries`).
    @ObservationIgnored private(set) var facts = AppUpdateFacts()

    /// The build kept with the fleet's last reading, as the store starts. Only a build that reads the channel draws
    /// from it: a development build never asks, so nothing would ever replace it.
    func start(kept: WaitingBuild?) {
        keptWaiting = KeptReading(installer.team != nil ? kept : nil)
        guard !listens else { return }
        listens = notify_register_dispatch(AppUpdatePolicy.signal, &signalToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.signalled = true }
        } == NOTIFY_STATUS_OK
    }

    /// Why this app cannot replace itself where it stands, or nil.
    var cannotReplace: String? { installer.cannotReplace }

    /// **A build of this app waits** (the sidebar's Update row, `FleetStore.updateWaits`): one that installs itself,
    /// one the channel offers, or the one that waited when the app last quit, while it is newer than this one.
    var buildWaits: Bool { waiting != nil || known?.offered == true || keptWaiting.reading?.waits(over: running) == true }

    /// **What his press of Update and Restart does now** (`pressInstall`), or nil at rest: the download, then its check
    /// and swap. The sidebar's Update says it.
    private(set) var pressed: AppUpdateInstaller.Step?
    /// Why his last press of Update and Restart stopped. The sidebar's Update then says Try again, with this under the
    /// pointer.
    private(set) var pressFailure: String?

    /// **Update and Restart of the window that the sidebar's Update opens** (`UpdateDialog`; the owner, 15 November 2026:
    /// "a small confirmation modal to update, and be able to do it from there"): the build that the window named goes in
    /// as the path with no press puts it in, and the app starts again at once, because he pressed it. Meanwhile the
    /// sidebar's Update says the download and then Restarting…; a press that stopped says Try again, with the reason
    /// under the pointer. Until that day one press of the banner did this with no question.
    func pressInstall(_ build: AppManifest) async {
        guard pressed == nil else { return }
        pressFailure = nil
        pressed = .downloading(-1)
        // A step that arrives after a failure was said must not bring the steps back.
        let failure = await installNow(build) { step in
            Task { @MainActor [weak self] in
                if let self, self.pressed != nil { self.pressed = step }
            }
        }
        guard let failure else { return }
        pressed = nil
        pressFailure = failure
    }

    func tick(store: FleetStore) {
        let now = Date()
        let active = NSApplication.shared.isActive
        if active, awaySince != nil { cameBack = true }
        awaySince = active ? nil : (awaySince ?? now)
        let published = installer.team != nil
        guard !working, published else { return }
        // **Before any hub answered this Mac** (the first run): the read goes to our channel, as for a Mac that has just
        // downloaded the app (the owner's yes of 14 November 2026). When a hub answers, what that read found waits for the
        // hub's own read, which has the fleet's channel, its track and its switch.
        let beforeHub = store.state == nil && !store.hubAnsweredBefore
        if readBeforeHub, !beforeHub {
            readBeforeHub = false
            askedAt = nil
            waiting = nil
        }
        if AppUpdatePolicy.shouldAsk(lastAsked: askedAt, failures: failures, cameBack: cameBack, signalled: signalled,
                                     now: now) {
            if beforeHub {
                askedAt = now
                cameBack = false
                signalled = false
                working = true
                Task { await askBeforeHub(store: store) }
                return
            }
            guard store.isFresh, let database = store.state?.db,
                  store.state?.ui_features?.contains(ReleaseState.feature) == true else { return }
            askedAt = now
            cameBack = false
            signalled = false
            working = true
            let hub = store.hub
            Task { await ask(hub: hub, database: database, store: store) }
            return
        }
        let setup = AppUpdatePolicy.setupHolds(beforeHub: beforeHub, setupAtRest: setupAtRest,
                                               wizardHolds: store.firstRunHolds)
        guard let build = waiting,
              AppUpdatePolicy.shouldInstall(automatic: automatic, published: published, offered: true,
                                            awaySince: awaySince,
                                            // a card in its own window: the restart would take it away (`NeedWindows.anyOpen`)
                                            // and an answer that waits with Undo (`AnswerHolds`)
                                            busy: store.sending || store.pending != nil || setup || NeedWindows.anyOpen
                                                || AnswerHolds.shared.busy,
                                            now: now) else { return }
        working = true
        Task { await install(build) }
    }

    /// The read before any hub answered: our channel, with no fleet id and not the early track. There is no fleet yet,
    /// so no switch of one: a new fleet takes its releases by itself until he turns that off (`releases_automatic` of the
    /// hub), and so does this app until then.
    private func askBeforeHub(store: FleetStore) async {
        defer { working = false }
        let reading = await AppUpdateChannel().read(installed: running)
        facts.read(reading)
        guard !reading.unreachable else { failed(); return }
        automatic = true
        readBeforeHub = true
        reached(reading)
        waiting = reading.offered ? reading.manifest : nil
        decided(store)
    }

    /// **Founderizer › Check for Updates…** (`UpdateCheck`): one read of our channel now, as the timed read asks it —
    /// with the fleet's channel, id and track from the hub, or from its last reading when the hub does not answer, and
    /// our channel's defaults before any hub answered. It decides nothing about what installs by itself.
    func readNow(store: FleetStore) async -> AppUpdateReading {
        var releases: ReleaseState?
        if let database = store.state?.db {
            releases = try? await HubClient().releases(hub: store.hub, database: database)
        }
        releases = releases ?? store.reading("releases") ?? store.keptReleases.reading(of: store.state?.db)
        let reading = await AppUpdateChannel(channel: releases?.channel ?? AppUpdate.defaultChannel,
                                             fleet: releases?.entitlement.fleet, early: releases?.early ?? false)
            .read(installed: running)
        facts.read(reading)
        if !reading.unreachable { reached(reading) }
        return reading
    }

    /// **Update and Restart** of that window: the build goes in as the path with no press puts it in, and the app
    /// starts again at once, because he pressed it. One install at a time: it waits for a read or an install of that
    /// path that runs. The words of a failure, or nil when the app restarts.
    func installNow(_ build: AppManifest,
                    progress: @escaping @Sendable (AppUpdateInstaller.Step) -> Void) async -> String? {
        while working {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return nil }
        }
        working = true
        defer { working = false }
        do {
            try await installer.install(build, progress: progress)
            AppAutoUpdate.relaunch(installer.bundle)
            return nil
        } catch {
            AppUpdateTries.failed(build: build.build, error: error)
            return (error as? LocalizedError)?.errorDescription
                ?? String(l10n: "The update stopped, and nothing on this Mac changed.")
        }
    }

    private func ask(hub: URL, database: String, store: FleetStore) async {
        defer { working = false }
        guard let releases = try? await HubClient().releases(hub: hub, database: database) else { failed(); return }
        automatic = releases.automatic
        guard automatic else { waiting = nil; reached(nil); decided(store); return }
        let reading = await AppUpdateChannel(channel: releases.channel, fleet: releases.entitlement.fleet,
                                             early: releases.early ?? false)
            .read(installed: running)
        facts.read(reading)
        guard !reading.unreachable else { failed(); return }
        reached(reading)
        waiting = reading.offered ? reading.manifest : nil
        decided(store)
    }

    /// This launch's own read decided what waits: it replaces the build kept from the last launch, and goes to disk with
    /// the fleet's reading for the next launch's first frame (`WaitingBuild`).
    private func decided(_ store: FleetStore) {
        keptWaiting = KeptReading()
        store.keepForNextLaunch(waiting.map(WaitingBuild.init), as: "app-update")
    }

    /// A read that failed: the next one comes sooner, nothing this launch knows changes, and the build kept from the last
    /// launch goes (`keptWaiting`).
    private func failed() {
        failures += 1
        failingSince = failingSince ?? Date()
        keptWaiting.readFailed()
    }

    /// A read that answered: the usual pace again, and the channel's answer kept.
    private func reached(_ reading: AppUpdateReading?) {
        failures = 0
        failingSince = nil
        if let reading { known = reading }
    }

    private func install(_ build: AppManifest) async {
        defer { working = false }
        do {
            try await installer.install(build)
            failure = nil
            // He was away from the app as the install began: the new build starts behind the app he works in, which
            // keeps his keys; in front when he came back to this app during the install.
            AppAutoUpdate.relaunch(installer.bundle, front: NSApp.isActive)
        } catch {
            AppUpdateTries.failed(build: build.build, error: error)
            failure = (error as? LocalizedError)?.errorDescription
                ?? String(l10n: "The update stopped, and nothing on this Mac changed.")
            waiting = nil
        }
    }

    /// Start the new build and leave. `front`: the new build comes to the front, as after his press. **An install of
    /// its own, while he is away, starts it behind the app he works in** (the review of the owner's "Build ideas 1–5" of
    /// 16 November 2026): it came to the front, so the keys that he typed there went to its chat's box, which takes them.
    /// **The new build starts only after this process is gone** (`AppRelaunch`): opened while this one still ran, it
    /// was a second instance under this one's entry, and the Dock showed two icons (20 November 2026).
    static func relaunch(_ bundle: URL, front: Bool = true) {
        guard AppRelaunch.start(waitingFor: ProcessInfo.processInfo.processIdentifier, bundle: bundle,
                                front: front) != nil else {
            // No waiter started: the way of before, which starts the new build at once (two Dock icons).
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.activates = front
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in
                Task { @MainActor in NSApplication.shared.terminate(nil) }
            }
            return
        }
        NSApplication.shared.terminate(nil)
    }
}
