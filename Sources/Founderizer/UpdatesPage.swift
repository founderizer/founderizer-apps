import AppKit
import FleetCore
import Observation
import SwiftUI

/// Updates (PRODUCT.md 4.3; the hub's `GET /ui/releases` and its three presses).
///
/// **Updates** answers three questions and no more: which release this fleet runs, which one is newer, and whether
/// it takes a new one by itself. **It has no second group.** The subscription stood under these rows (the owner's
/// map of 28 October 2026, D-4) until Founderizer became free and open source on 10 November 2026, with no
/// subscription and no account: the plan, the claim key's field, Open account and See the plans went with it.
///
/// A git revision and a fleet id are this app's own business. It needs both and shows neither, because neither is
/// anything a person reads (the owner, 19 October 2026: "IDs like the attached are not useful at all for the
/// viewer"). The release history went with them: what matters about a release that is not this one is whether a
/// newer one is there to take, and the one line says that.
@MainActor @Observable
final class UpdatesModel {
    private(set) var state: ReleaseState?
    private(set) var failed = false
    private(set) var busy = false
    private(set) var error: String?

    /// A model that begins with the reading the store kept, so its page draws it in its first frame.
    init(state: ReleaseState? = nil) { self.state = state }

    /// What one visit said goes with it: a refusal's words. The reading stays.
    func left() { error = nil }

    func read(store: FleetStore) async {
        guard let database = store.state?.db else { return }
        let hub = store.hub
        let read = try? await HubClient().releases(hub: hub, database: database)
        guard store.hub == hub, store.state?.db == database else { return }
        // The store's reading too, which the sidebar's Update row draws: an update taken here takes the row away.
        if let read { state = read; failed = false; store.keep(read, as: "releases") } else { failed = true }
    }

    /// `POST /ui/releases/check`: ask the channel now.
    func check(store: FleetStore) async { await press(store) { client, hub, database in
        _ = try await client.checkReleases(hub: hub, database: database, client: store.installation)
    } }

    /// `POST /ui/releases/update`: the one click. It answers as soon as the run started; the run takes minutes and
    /// this screen reads where it stands.
    func update(store: FleetStore) async {
        // **A press while running work holds the release waits for that work** (fix round 3, item 20): the hub refuses
        // an update while a turn runs, so the press is kept here, the row says what it waits for, and the update goes
        // the moment the fleet's reading says no turn runs. A new hub or generation drops it.
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
        }
    }
    /// He pressed Update while a release waited for running work: it goes when no turn runs (`update`).
    private(set) var queued = false

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
        } catch let HubError.refusal(_, words) { error = words }
        catch { self.error = String(l10n: "The hub has not answered. Try again.") }
    }
}

/// Settings › Updates: one card of three rows. The read of `GET /ui/releases` belongs to the page, so the poll does
/// not start again while it shows. **No sidebar of its own** (the owner, 24 October 2026: "under Update no submenu is
/// needed").
struct UpdatesPage: View {
    @Bindable var store: FleetStore
    /// The releases, kept by the store with what was read last (`FleetStore.pageModel`): the page draws that
    /// reading in its first frame, and the read that starts then changes only what changed. The app's own
    /// check is kept too, so a visit does not ask the channel again for an answer it has.
    private var model: UpdatesModel { store.pageModel("releases") { UpdatesModel(state: store.reading("releases")) } }
    private var app: AppUpdateModel {
        store.pageModel("releases.app") { AppUpdateModel(reading: store.reading(Self.channelName)) }
    }
    private var offered: Bool { store.state?.ui_features?.contains(ReleaseState.feature) == true }
    /// The releases, read before the page first opens (`PagePrefetch`).
    static let prefetch = PagePrefetch("releases", feature: ReleaseState.feature) { try await HubClient().releases(hub: $0, database: $1) }
    /// **The channel's last answer about this Mac's build is kept by the store and read before the page first opens**
    /// (T-01): the row "Founderizer for Mac" got its two orange lines 0.34–0.45 s after the page, which pushed every row
    /// under it 24 pt. A read that does not reach the channel keeps nothing.
    static let channelName = "releases.app.channel"
    static let channelPrefetch = PagePrefetch(channelName, feature: ReleaseState.feature, apart: true) { hub, database in
        let releases = try await HubClient().releases(hub: hub, database: database)
        let reading = await AppUpdateChannel(channel: releases.channel, fleet: releases.entitlement.fleet,
                                             early: releases.early ?? false)
            .read(installed: AppVersion.running)
        guard !reading.unreachable else { throw HubError.unavailable }
        return reading
    }

    var body: some View {
        ReleasesSection(store: store, model: model, app: app, offered: offered)
            .task(id: "\(store.hub)/\(store.state?.db ?? "")") { await poll() }
            .task(id: "\(model.state?.channel ?? "")/\(model.state?.entitlement.fleet ?? "")/\(model.state?.early ?? false)") {
                await app.check(channel: model.state?.channel, fleet: model.state?.entitlement.fleet,
                                early: model.state?.early ?? false)
                keepChannel()
            }
            .onChange(of: store.updates.known, initial: true) { _, known in app.adopt(known) }
            .onDisappear { model.left() }
    }

    /// The channel's answer that the row draws, for the next visit's first frame.
    private func keepChannel() {
        if let reading = app.reading { store.keep(reading, as: Self.channelName) }
    }

    /// Reads the updates every 15 seconds while the page shows, every 3 while a run goes on.
    private func poll() async {
        while !Task.isCancelled {
            if store.isFresh, offered { await model.read(store: store) }
            guard !Task.isCancelled else { return }
            do { try await store.nap(model.state?.running == true ? 3 : 15) } catch { return }
        }
    }
}

/// **Updates.** Three rows, and the owner reads the whole screen in a glance: the release his fleet runs, the
/// build this Mac runs, and whether a new release is taken without him. A button appears on a row only when
/// there is something to install, and Check for updates stands in the header whenever the channel can be asked.
private struct ReleasesSection: View {
    @Bindable var store: FleetStore
    let model: UpdatesModel
    let app: AppUpdateModel
    let offered: Bool
    /// He pressed Check for updates, and its two reads are out.
    @State private var checking = false
    /// This visit drew the card before our channel's first answer: the Mac row keeps its line for this visit.
    @State private var reserved = false

    var body: some View {
        FleetPage("Updates") {
            Group {
                if !offered {
                    FormSection { FormEmpty("This hub does not serve the release channel yet.", symbol: "arrow.down.circle") }
                } else if let state = model.state {
                    // From the hub at once; only the row of this Mac's own build waits for our channel (`macRow`).
                    standing(state)
                } else if model.failed || store.connectionError != nil {
                    // While the hub does not answer nothing is read: the failed row, never "Reading the updates…". **Not
                    // while the window's notice says the outage** (`FleetStore.hubNoticeShows`; fix round 3, item 33):
                    // it is said once, over the page.
                    if !store.hubNoticeShows {
                        FormSection { FormRow("Founderizer cannot read the updates now.", detail: String(l10n: "It reads again when the hub answers.")) }
                    }
                } else {
                    LoadingLine(String(l10n: "Reading the updates…"))
                }
            }
        } actions: {
            // There from the first frame, as the page's own reading is not what it needs.
            if offered {
                // **His own check, once it has gone on for a second, is the pages' one loading look**: the moving
                // word in the header, where a spinner stood (a second look of waiting). One that answers sooner
                // shows nothing, and so do the check the page makes by itself, an update and a run: their rows say
                // what goes on.
                if checking { LoadingLine(String(l10n: "Checking…")).fixedSize() }
                // **A button that names what it does.** It was a refresh mark with these words behind it, because
                // "Check again" named no object (19 October 2026); the mark then read as a refresh of the page and
                // nothing more (24 October 2026: "The button to Install update or check for Updates should be
                // visible, it just looks like a Refresh icon"). An update to take is the white button on its own
                // row, so the two never stand in one place.
                Button("Check now") {
                    Task {
                        let start = ContinuousClock.now
                        checking = true
                        await checkBoth()
                        if let reading = app.reading { store.keep(reading, as: UpdatesPage.channelName) }
                        // Words that showed stand half a second, so they never blink (`FleetStore.settle`).
                        await store.settle(since: start)
                        checking = false
                    }
                }
                    .buttonStyle(FleetOutlineButtonStyle())
                    .disabled(model.busy || (app.busy && !app.checking) || model.state?.running == true || !store.canWrite)
                    .help("Ask our channel for a new release of your fleet and of this app now")
                    .accessibilityIdentifier("releases-check")
            }
        }
        // The card drawn before our channel answered keeps the Mac row's line for the rest of this visit.
        .onChange(of: model.state.map { !app.knows(channel: $0.channel, fleet: $0.entitlement.fleet, early: $0.early ?? false) } ?? false, initial: true) { _, waits in
            if waits { reserved = true }
        }
    }

    private func standing(_ state: ReleaseState) -> some View {
        let stand = state.stand
        // This build ships no release key and neither does the hub, so both sides refuse every manifest. That is
        // one fact, and the fleet's line already says it: the app's row then shows the build it runs and no more.
        let quiet = !state.have_release_key && !AppUpdate.carriesKey
        // A build that installs itself while he is away is Update available too: the row has the read that found it.
        let mac = app.says(quiet: quiet)
        // Reads that fail are said only once they have failed for a day; until then the row keeps what it knew.
        let failing = AppUpdateWords.failing(since: store.updates.failingSince, now: Date())
        // **Each row is its label and its value, with its button after the value while there is something to take**
        // (D-2, the owner's yes of 28 October 2026: "Updates: three rows with label and value only"; and 6 November
        // 2026, of the version an Update hid: "here i should still see the current version of the Founderizer", and of
        // Your fleet: "Yes, same there"). What the fleet's line said is the row's hover, and the reason an Update waits
        // is its button's; a line stays only for what went wrong, in orange, and for an update of this Mac that goes on.
        let macWorking = app.installed || app.step != nil || app.failure != nil
        return FormSection(footer: model.error ?? app.installer.cannotReplace ?? store.updates.failure) {
            FormRow("Your fleet", symbol: "shippingbox", warning: stand.warn ? stand.says : nil) {
                // While it waits for running work there is no button when updates are automatic (the hub takes it at
                // the first moment no turn runs), and it acts when they are off: its press waits (`update`).
                if let take = stand.take, !stand.waiting || !state.automatic && !model.queued {
                    // The release this fleet runs stays at the right, before the one the button takes.
                    HStack(spacing: 12) {
                        if let current = state.current {
                            Text(current.version).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                                .accessibilityIdentifier("releases-running")
                        }
                        Button("Update to \(take.version)") { Task { await model.update(store: store) } }
                            .buttonStyle(FleetPrimaryButtonStyle())
                            .disabled(model.busy || !store.canWrite)
                            .accessibilityIdentifier("releases-update")
                    }
                } else {
                    Text(stand.value).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                }
            }.help(stand.warn ? "" : stand.says)
            macRow(line: app.reading?.refused == true ? (mac ?? "", true)
                        : macWorking ? mac.map { ($0, false) } : quiet ? nil : failing.map { ($0, true) },
                   reserve: reserved || !app.knows(channel: state.channel, fleet: state.entitlement.fleet, early: state.early ?? false), quiet: quiet)
            FormRow("Automatic updates", symbol: "clock.arrow.circlepath") {
                Toggle("Automatic updates", isOn: Binding(get: { state.automatic },
                                                          set: { on in Task { await model.automatic(on, store: store) } }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .disabled(model.busy || !store.canWrite).accessibilityIdentifier("releases-auto")
            }
        }
    }

    /// **"Founderizer for Mac"**: its label, its value — the version this Mac runs, which stays when a button offers the
    /// next one (the owner, 6 November 2026: "here i should still see the current version of the Founderizer") — and
    /// one line only for an update of this Mac that goes on, or for what went wrong. **Before our channel's first answer
    /// its line is kept for it** (fix round 2, the lead's call on item 6): the one loading look stands in it after a
    /// second, and the answer takes that place, so nothing under the row moves — the answer pushed every row under it
    /// 24 pt — and the line stays kept for this visit. The rest of the card draws from the hub at once.
    private func macRow(line: (words: String, warning: Bool)?, reserve: Bool, quiet: Bool) -> some View {
        HStack(alignment: .center, spacing: 0) {
            RowMark { Image(systemName: "app.badge").font(IconMetrics.symbol(15)).foregroundStyle(FleetStyle.text) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Founderizer for Mac").font(FormMetrics.title).foregroundStyle(FleetStyle.text)
                if let line {
                    Text(line.words).font(FormMetrics.detail).foregroundStyle(line.warning ? Color.orange : FleetStyle.muted)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else if reserve {
                    // The room is kept from the first frame: a held line is nothing before its second.
                    Color.clear.frame(height: 15).overlay(alignment: .leading) { Held { ShimmeringWords(text: String(l10n: "Checking…")) } }
                }
            }.padding(.vertical, 10)
            Spacer(minLength: 16)
            HStack(spacing: 12) {
                if app.installed || app.offered != nil {
                    Text(AppUpdateWords.version(app.running)).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                        .accessibilityIdentifier("app-update-running")
                }
                if app.installed {
                    Button("Restart Founderizer") { app.restart() }
                        .buttonStyle(FleetPrimaryButtonStyle())
                        .accessibilityIdentifier("app-update-restart")
                } else if let build = app.offered {
                    Button("Update to \(build.version)") { Task { await app.update() } }
                        .buttonStyle(FleetPrimaryButtonStyle())
                        .disabled(app.installing || app.installer.cannotReplace != nil)
                        .accessibilityIdentifier("app-update-install")
                } else {
                    Text(app.word(quiet: quiet)).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                }
            }.padding(.vertical, 8)
        }
        .font(FormMetrics.text).padding(.horizontal, FormMetrics.rowInset)
        .frame(minHeight: line != nil || reserve ? FormMetrics.twoLineRow : FormMetrics.row)
        .contentShape(Rectangle()).accessibilityElement(children: .contain)
    }

    /// One press asks both channels, because the screen answers for both.
    private func checkBoth() async {
        async let fleet: Void = model.check(store: store)
        async let mac: Void = app.check(channel: model.state?.channel, fleet: model.state?.entitlement.fleet,
                                        early: model.state?.early ?? false, force: true)
        _ = await (fleet, mac)
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
