import AppKit
import FleetCore
import Observation
import SwiftUI

/// The fleet's updates (PRODUCT.md 4.3; the hub's `GET /ui/releases` and its presses), which the sidebar's Update and
/// Settings › General › Updates both draw.
///
/// **There is no Updates page** (the owner, 15 November 2026: "if I had an update available I wanted to see a button
/// above the settings one, where I can click, I see a small confirmation modal to update, and be able to do it from
/// there. I do not want to go to the settings > update page. This applies to the fleet and to the app. we can remove the
/// settings > Updates page and move the automatic updates switch to General, where we can also see the current
/// versions"). An update is taken from the sidebar's Update and the window it opens (`UpdateDialog`). General shows the
/// release this fleet runs, the build this Mac runs and the Automatic updates switch. The page's Check now went with the
/// page: the hub asks our channel every 15 minutes, this Mac every five minutes and when he comes back to the app, and
/// Founderizer › Check for Updates… stays.
///
/// A git revision and a fleet id are this app's own business. It needs both and shows neither, because neither is
/// anything a person reads (the owner, 19 October 2026: "IDs like the attached are not useful at all for the viewer").
@MainActor @Observable
final class UpdatesModel {
    private(set) var state: ReleaseState?
    private(set) var failed = false
    /// When the first of the reads that failed in a row failed: one break of them says nothing
    /// (`FleetStore.pageReadingIsOld`).
    private(set) var failedSince: ContinuousClock.Instant?
    private(set) var busy = false
    private(set) var error: String?

    /// A model that begins with the reading the store kept, so what draws it has it in its first frame.
    init(state: ReleaseState? = nil) { self.state = state }

    /// **The one model of the fleet's updates for this hub generation**, which the sidebar's Update and General share:
    /// the press of the one shows in the other.
    static func of(_ store: FleetStore) -> UpdatesModel {
        store.pageModel("releases") { UpdatesModel(state: store.reading("releases")) }
    }

    /// What one visit of General said goes with it: a refusal's words. The reading stays.
    func left() { if !pressed && !queued { error = nil } }
    /// **A new visit counts its own break** (`failedSince`): reads that failed in an earlier visit say nothing to it at
    /// its first failed read.
    func visited() { if failedSince != nil { failedSince = .now } }

    func read(store: FleetStore) async {
        guard let database = store.state?.db else { return }
        let hub = store.hub
        let read = try? await HubClient().releases(hub: hub, database: database)
        guard store.hub == hub, store.state?.db == database else { return }
        // The store's reading too, which the sidebar's Update draws: an update taken here takes it away.
        if let read { state = read; failed = false; failedSince = nil; store.keep(read, as: "releases") }
        else { failed = true; failedSince = failedSince ?? .now }
        if read?.running == false { pressed = false }       // the run he started has ended, however it ended
    }

    /// `POST /ui/releases/update`, from the window that the sidebar's Update opens. It answers as soon as the run
    /// started; the run takes a minute or more, and the sidebar's Update says Updating… until it ends.
    func update(store: FleetStore) async {
        // **A press while running work holds the release waits for that work** (fix round 3, item 20): the hub refuses
        // an update while a turn runs, so the press is kept here, the sidebar's Update says what it waits for, and the
        // update goes the moment the fleet's reading says no turn runs. A new hub or generation drops it.
        let hub = store.hub, database = store.state?.db
        if state?.stand.waiting == true {
            queued = true
            defer { queued = false }
            while state?.stand.waiting == true, state?.stand.take != nil {
                do { try await store.nap(3) } catch { return }
                guard store.hub == hub, store.state?.db == database else { return }
                await read(store: store)
            }
            guard state?.stand.take != nil else { return }
        }
        await press(store) { client, hub, database in
            _ = try await client.updateRelease(hub: hub, database: database, client: store.installation)
            pressed = true
        }
    }
    /// He pressed Update while a release waited for running work: it goes when no turn runs (`update`).
    private(set) var queued = false
    /// The hub took his press of Update, and its run has not ended: the fleet's row says Updating from the press on
    /// (`ReleaseState.stand(pressed:)`), and not only once the run has written its own row.
    private(set) var pressed = false

    /// **The sidebar's Update while his press of the fleet's goes on**, or nil: what a press that waits for running work
    /// waits for ("Waits for a task"), then Updating… until the run ends.
    var working: String? {
        if queued, let stand = state?.stand, stand.waiting, !stand.value.isEmpty { return stand.value }
        return pressed || queued ? String(l10n: "Updating…") : nil
    }

    /// `POST /ui/releases/auto`: automatic updates on or off.
    func automatic(_ on: Bool, store: FleetStore) async { await press(store) { client, hub, database in
        _ = try await client.automaticReleases(on, hub: hub, database: database, client: store.installation)
    } }

    private func press(_ store: FleetStore,
                       _ call: (HubClient, URL, String) async throws -> Void) async {
        guard !busy, let database = store.state?.db else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await call(HubClient(), store.hub, database)
            await read(store: store)
        } catch let HubError.refusal(refused) { error = refused.words }
        catch { self.error = String(l10n: "The hub has not answered. Try again.") }
    }
}

/// **Settings › General › Updates** (the owner, 15 November 2026: "move the automatic updates switch to General, where
/// we can also see the current versions"): Your fleet with the release it runs, Founderizer for Mac with the build it
/// runs, and the Automatic updates switch. **No button**: an update is taken from the sidebar's Update. What went wrong
/// stays where the Updates page said it: an orange line under its row, and a refusal of the hub under the card.
///
/// **The section always stands, with this Mac's row** (the owner, 16 November 2026: "I requested for the app version
/// and the fleet version to appear under Settings > General. However, theyre nowhere to be seen"). Until then it was
/// a `Group` that held nothing until the model had a reading, and the read that gives the model one was that `Group`'s
/// task: SwiftUI starts no task on a view with no content. The sidebar's Update makes the model at launch
/// (`FleetStore.fleetUpdateWords`), before the first read of the releases, so on his Mac the model never had one and
/// General showed neither version for the whole launch. Now the task stands on the section, which always holds this
/// Mac's row; the fleet's rows draw the model's reading, or the one that the store read under the hood
/// (`FleetStore.releasesTick`, the prefetch) until the model has its own. This Mac's build needs nothing of the hub, so
/// its row shows also from a hub without the releases.
struct UpdatesSection: View {
    @Bindable var store: FleetStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var model: UpdatesModel { UpdatesModel.of(store) }
    /// The releases, read before General first opens (`PagePrefetch`).
    static let prefetch = PagePrefetch("releases", feature: ReleaseState.feature) { try await HubClient().releases(hub: $0, database: $1) }

    var body: some View {
        let fleet = store.state?.ui_features?.contains(ReleaseState.feature) == true
        let state: ReleaseState? = fleet ? model.state ?? store.reading("releases") : nil
        // Reads of our channel that fail are said only once they have failed for a day.
        let failing = AppUpdateWords.failing(since: store.updates.failingSince, now: Date())
        FormSection("Updates", footer: model.error ?? store.updates.cannotReplace ?? store.updates.failure) {
            if let state {
                fleetRow(state)
            } else if fleet, model.failed && store.pageReadingIsOld(failedSince: model.failedSince) || store.connectionError != nil,
                      !store.hubNoticeShows {
                // While the hub does not answer nothing is read: the failed row, never a loading line. **Not while the
                // window's notice says the outage** (`FleetStore.hubNoticeShows`): it is said once, over the page.
                // **One break of the hub says nothing** (17 November 2026): only once the reads have failed one whole
                // break.
                FormRow("Founderizer cannot read the updates now.", detail: String(l10n: "It reads again when the hub answers."))
            }
            FormRow("Founderizer for Mac", symbol: "app.badge", warning: failing) {
                Text(AppUpdateWords.version(AppVersion.running)).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                    .accessibilityIdentifier("app-update-running")
            }
            if let state { automaticRow(state) }
        }
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(fleet)") { if fleet { await poll() } }
        .onDisappear { model.left() }
    }

    /// Reads the updates every 15 seconds while General shows, every 3 while a run goes on.
    private func poll() async {
        model.visited()
        while !Task.isCancelled {
            if store.isFresh { await model.read(store: store) }
            guard !Task.isCancelled else { return }
            // Also 3 s after a read that failed, as the lists do: its row goes as soon as the hub is back.
            do { try await store.nap(model.state?.running == true || model.failed ? 3 : 15) } catch { return }
        }
    }

    /// The release this fleet runs, or what goes on in its place.
    private func fleetRow(_ state: ReleaseState) -> some View {
        let stand = state.stand(pressed: model.pressed)
        return FormRow("Your fleet", symbol: "shippingbox", warning: stand.warn ? stand.says : nil) {
            if stand.working && store.isFresh && !reduceMotion {
                // A run moves, as every other wait of this app (the owner, 14 November 2026: "clicked on Update
                // fleet, seems stuck, not a great ux"). Under Reduce Motion it stands.
                ShimmeringWords(text: stand.value).fixedSize()
                    .accessibilityElement().accessibilityLabel(stand.value).accessibilityIdentifier("releases-updating")
            } else {
                // The release this fleet runs; what stands in its place when there is none ("Nothing to check").
                Text(stand.working ? stand.value : state.current?.version ?? stand.value)
                    .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                    .accessibilityIdentifier("releases-running")
            }
        }.help(stand.warn ? "" : stand.says)
    }

    private func automaticRow(_ state: ReleaseState) -> some View {
        FormRow("Automatic updates", symbol: "clock.arrow.circlepath") {
            Toggle("Automatic updates", isOn: Binding(get: { state.automatic },
                                                      set: { on in Task { await model.automatic(on, store: store) } }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .disabled(model.busy || !store.canWrite).accessibilityIdentifier("releases-auto")
        }
    }
}

/// The one way into what a page keeps for a bad day: a quiet line that opens the rest in place. It is here, and not
/// in the shared components, until the page scaffold takes it.
struct FleetDetailsToggle: View {
    @Binding var open: Bool
    let identifier: String

    /// `-showDetails YES` opens every Details of the app at once, which is how what is behind one can be looked at
    /// without clicking to it. The argument domain is not written to the app's settings, so it leaves no trace.
    static var asked: Bool { UserDefaults.standard.bool(forKey: "showDetails") }

    var body: some View {
        Button {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { open.toggle() }
        } label: {
            HStack(spacing: 5) {
                Text(open ? "Hide details" : "Details")
                Image(systemName: open ? "chevron.up" : "chevron.down").font(IconMetrics.symbol(9))
            }
            .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
            .padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.vertical, -IconMetrics.reach).padding(.horizontal, 2)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }
}
