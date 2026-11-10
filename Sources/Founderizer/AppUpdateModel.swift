import AppKit
import FleetCore
import Observation
import SwiftUI

/// Founderizer's own update, as one row of the Updates screen beside the fleet's (the owner's requirement 10).
///
/// The fleet updates itself from our signed release channel. This is the same channel, the same key and the same
/// discipline for the app that drives it: the signature decides, a held build is never offered, and a refusal of our
/// channel says so plainly instead of looking broken.
///
/// **This row is the press for a build now.** Opening this screen asks the channel and changes nothing. Update
/// downloads, checks and replaces. The restart is a second press, so the app never disappears from under the
/// owner in the middle of something. Without any press, `AppAutoUpdate` puts the same build in place while he is
/// away from the app (22 October 2026).
@MainActor @Observable
final class AppUpdateModel {
    private(set) var reading: AppUpdateReading?
    private(set) var checking = false
    private(set) var step: AppUpdateInstaller.Step?
    private(set) var failure: String?
    private(set) var installed = false
    /// The channel and fleet of the last answer, so that one screen does not ask the same question twice.
    private var asked: String?
    /// The channel and fleet whose read has come back, reached or not.
    private(set) var answered: String?

    /// A model that begins with the channel's last answer that the store kept (`UpdatesPage.channelPrefetch`), so the
    /// row is whole in its first frame.
    init(reading: AppUpdateReading? = nil) { self.reading = reading }

    /// The row has what it needs to draw: an answer of the channel, kept or new, or the read of this channel and fleet
    /// came back without one.
    func knows(channel: String?, fleet: String?, early: Bool) -> Bool {
        reading != nil || answered == Self.key(channel: channel, fleet: fleet, early: early)
    }

    static func key(channel: String?, fleet: String?, early: Bool) -> String { "\(channel ?? "")/\(fleet ?? "")/\(early)" }

    /// This app's own build. nil when the bundle does not say, and then nothing is ever offered.
    let running = AppVersion.running
    /// Where this app is, and whether it can be replaced where it stands.
    let installer = AppUpdateInstaller()

    var busy: Bool { checking || installing }
    /// A build is being put in place: its download, its check, its swap. **Update to … is dimmed for this alone, and
    /// not for a read of the channel** (10 November 2026): the page asks the channel at each visit, so the white
    /// button drew dimmed for the 233 ms of that read, and then white, every time he opened Updates while a build
    /// waited.
    var installing: Bool { step != nil && !installed }

    /// The build the button would take, and nothing when it would take none: a build that is held, or one this
    /// Mac already runs, is not something to offer to install.
    var offered: AppManifest? { reading?.offered == true ? reading?.manifest : nil }

    /// Ask the channel. The page asks once for each channel and fleet it learns — a Mac whose hub answers after
    /// this screen opened is asked again with its fleet id, and not left with the answer for a Mac that had none.
    /// The owner's own press asks whatever the last answer was. **A read that does not reach the channel changes
    /// nothing on the row**: it keeps the last state it knew, and the app asks again by itself.
    func check(channel: String?, fleet: String?, early: Bool, force: Bool = false) async {
        guard !busy else { return }
        let asking = Self.key(channel: channel, fleet: fleet, early: early)
        guard force || asked != asking else { return }
        checking = true
        failure = nil
        asked = asking
        defer { checking = false; answered = asking }
        let site = AppUpdateChannel(channel: channel ?? AppUpdate.defaultChannel, fleet: fleet, early: early)
        let fresh = await site.read(installed: running)
        // Not under an update that he started while this read was on its way: its row says its steps.
        if !fresh.unreachable, step == nil, !installed { reading = fresh }
    }

    /// The last read of `AppAutoUpdate` that reached the channel, which is the newest state known: the row says it,
    /// with its Update to … when that read offers a build. Never in the middle of an update.
    func adopt(_ known: AppUpdateReading?) {
        guard let known, step == nil, !installed else { return }
        reading = known
    }

    /// The one press: download, check, replace. The app is not restarted by it. It takes the build that the row offers,
    /// also while a read of the channel is on its way.
    func update() async {
        guard !installing, !installed, let manifest = reading?.manifest, reading?.offered == true else { return }
        failure = nil
        step = .downloading(-1)
        let installer = self.installer
        let report: @Sendable (AppUpdateInstaller.Step) -> Void = { [weak self] step in
            Task { @MainActor in self?.step = step }
        }
        do {
            _ = try await installer.install(manifest, progress: report)
            step = .installed
            installed = true
        } catch {
            failure = (error as? LocalizedError)?.errorDescription
                ?? "The update stopped, and nothing on this Mac changed."
            step = nil
        }
    }

    /// Start the new build and leave, from the owner's own press.
    func restart() { AppAutoUpdate.relaunch(installer.bundle) }

    /// The one line under "Founderizer for Mac".
    ///
    /// `quiet` is true when the fleet's own line has already said that nothing can be checked, because this build
    /// carries no release key either. Then this row shows the build it runs and nothing more: the reason is on the
    /// screen once, where the owner reads it first. nil while nothing is known yet: the version at the right says it.
    func says(quiet: Bool) -> String? {
        if installed { return "The new Founderizer is in place. It starts when you say so, and not before." }
        if let step { return step.says }
        if let failure { return failure }
        if quiet { return running.map { "Founderizer \($0.name)" } ?? "This build does not say which one it is." }
        return AppUpdateWords.state(reading)
    }

    /// The short word at the right when this row offers no press: the version this Mac runs, with no build number.
    func word(quiet: Bool) -> String {
        if quiet { return "Nothing to check" }
        if reading?.refused == true { return "Cannot check" }
        if reading?.manifest?.hold == true { return "Held" }
        return AppUpdateWords.version(running)
    }
}

/// **Founderizer updates itself, without a press** (the owner, 22 October 2026: "do they get the latest updates,
/// improvements and bug fixes automatically? it must be like that!").
///
/// The fleet's own poll calls `tick` every few seconds, as it calls the copy keeper's. It reads the channel at the
/// start and every hour, and after a read that failed again after 1, 5 and 15 minutes (`AppUpdatePolicy`), and only
/// while the fleet's Automatic updates switch is on: one switch for the fleet and the Mac that drives it. A read that
/// fails changes nothing it knew: the build that waits still waits, and the Updates page keeps its last state. An
/// offered build is put in place exactly as the Update button puts it — downloaded, checked against the signed manifest
/// and against Apple's signature of the running app, swapped — and the app then starts again, but only after the owner
/// has been away from it for two minutes with no request of his on its way (`AppUpdatePolicy`). Only a Developer ID
/// build updates itself: a development build made on this Mac is never swapped for a published one.
@MainActor @Observable
final class AppAutoUpdate {
    /// The build that installs itself the next time he is away from the app, or nil.
    private(set) var waiting: AppManifest?
    /// Why the last attempt stopped, for the Updates page. The next read tries again.
    private(set) var failure: String?
    /// The last read that reached the channel, which the Updates page keeps when its own read does not.
    private(set) var known: AppUpdateReading?
    /// Since when every read has failed, or nil while they reach the channel; the page says so only after long.
    private(set) var failingSince: Date?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var askedAt: Date?
    @ObservationIgnored private var awaySince: Date?
    @ObservationIgnored private var automatic = false
    @ObservationIgnored private var working = false
    @ObservationIgnored private let running = AppVersion.running
    @ObservationIgnored private let installer = AppUpdateInstaller()
    /// **The build that waited when the app last quit** (`WaitingBuild`, kept with the fleet's reading; review B, round 3
    /// of 30 October 2026): the Update row draws from it in the launch's first frame, while it is newer than the build
    /// that runs, until this launch's own read decides what waits. **A read that fails takes it away** (`KeptReading`,
    /// as the kept health and releases; review B, round 5): the Updates page that the row opens draws only this
    /// launch's reading (`known`), so the row stood for a build that the page did not show.
    private(set) var keptWaiting = KeptReading<WaitingBuild>()

    /// The build kept with the fleet's last reading, as the store starts. Only a build that reads the channel draws
    /// from it: a development build never asks, so nothing would ever replace it.
    func start(kept: WaitingBuild?) { keptWaiting = KeptReading(installer.team != nil ? kept : nil) }

    /// **A build of this app waits** (the sidebar's Update row, `FleetStore.updateWaits`): one that installs itself,
    /// one the channel offers, or the one that waited when the app last quit, while it is newer than this one.
    var buildWaits: Bool { waiting != nil || known?.offered == true || keptWaiting.reading?.waits(over: running) == true }

    func tick(store: FleetStore) {
        let now = Date()
        awaySince = NSApplication.shared.isActive ? nil : (awaySince ?? now)
        let published = installer.team != nil
        guard !working, published else { return }
        if AppUpdatePolicy.shouldAsk(lastAsked: askedAt, failures: failures, now: now) {
            guard store.isFresh, let database = store.state?.db,
                  store.state?.ui_features?.contains(ReleaseState.feature) == true else { return }
            askedAt = now
            working = true
            let hub = store.hub
            Task { await ask(hub: hub, database: database, store: store) }
            return
        }
        guard let build = waiting,
              AppUpdatePolicy.shouldInstall(automatic: automatic, published: published, offered: true,
                                            awaySince: awaySince, busy: store.sending || store.pending != nil,
                                            now: now) else { return }
        working = true
        Task { await install(build) }
    }

    private func ask(hub: URL, database: String, store: FleetStore) async {
        defer { working = false }
        guard let releases = try? await HubClient().releases(hub: hub, database: database) else { failed(); return }
        automatic = releases.automatic
        guard automatic else { waiting = nil; reached(nil); decided(store); return }
        let reading = await AppUpdateChannel(channel: releases.channel, fleet: releases.entitlement.fleet,
                                             early: releases.early ?? false)
            .read(installed: running)
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

    /// A read that answered: the hourly pace again, and the channel's answer kept for the page.
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
            AppAutoUpdate.relaunch(installer.bundle)
        } catch {
            failure = (error as? LocalizedError)?.errorDescription
                ?? "The update stopped, and nothing on this Mac changed."
            waiting = nil
        }
    }

    /// Start the new build and leave.
    static func relaunch(_ bundle: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }
}
