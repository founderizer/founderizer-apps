import AppKit
import FleetCore
import SwiftUI
import UniformTypeIdentifiers

/// Putting a copy of the fleet back, from the app (owner API 1.5, `POST /ui/restore`).
///
/// It is offered in two places because they are two moments. **At the claim**, which is the one that matters:
/// standing in front of a fresh hub on the day his old machine died, the next thing the app offers is a choice —
/// start a new fleet, or put a copy back. **On System status**, beside Save a copy, because the two belong
/// together and because a man who pressed past the claim screen needs a way back in. `RESTORE.md`, which the hub
/// writes into every copy, names both.
///
/// Four things this has to get right, and they are all here:
///
///   - **It says what is in the copy before it sends it.** `fleet.json` is read on this Mac (`ChosenCopy`), so he
///     reads the date, the fleet and the agents and can tell two copies apart. He will have seven in a folder
///     once copies are kept automatically.
///   - **A restore replaces a fleet.** On a hub that holds work the route answers 409; this shows what is there
///     and asks again before it sends `replace=yes`. It is the one irreversible button in the app.
///   - **It waits properly.** The hub stages the records and restarts itself to take them, so it goes away and
///     comes back with a new `db`. A hub that is not answering is not a failure while that is happening, and
///     nothing says the restore worked until that generation has really moved.
///   - **It says what is still missing afterwards.** A restored fleet has no Google token, no GitHub App key and
///     no MCP sign-in, because the copy carries no credential anywhere. `RestoreAfterwards` reads the copy's own
///     `hub_only` and names them in the order that unblocks the fleet fastest.
@MainActor @Observable
final class RestoreModel {
    enum Phase: Equatable {
        /// Nothing chosen. The one button is Restore a copy.
        case idle
        /// A copy is read and what is in it is on the screen. Nothing has been sent.
        case chosen
        /// The hub holds a fleet's work and refused. What it holds is on the screen, and the next press replaces it.
        case holdsWork
        case sending
        /// Sent and accepted: the hub is restarting to take the records.
        case restarting
        /// It has not come back. The copy may be staged, so the answer is to look, not to send again blindly.
        case lost
        /// This hub does not restart itself. The records wait beside its database for its next start.
        case staged
        /// The generation moved. The fleet is back.
        case landed
    }

    private(set) var phase: Phase = .idle
    private(set) var copy: ChosenCopy?
    private(set) var failure: String?
    /// What the hub answered when it refused because it already holds work, in its own words.
    private(set) var hubSaid: String?
    private(set) var holds: FleetHolds?
    private(set) var receipt: RestoreReceipt?

    /// The id of the send that is in flight. It stays the same across a retry, so a send that was lost in
    /// transport is replayed by the hub and never restores twice. A send with another `replace` is a different
    /// command to the hub — it compares the body it recorded — so changing that flag takes a new id, and only
    /// changing it does.
    private var sendID = UUID()
    private var sendReplace = false
    private var watch: RestoreWatch?
    private var began = Date()

    /// What this fleet must reconnect once the copy is in place.
    var afterwards: RestoreAfterwards? { copy?.afterwards }

    var busy: Bool { phase == .sending }
    /// Whether the app is in the middle of a restore and must not be walked away from quietly.
    var running: Bool { [.sending, .restarting].contains(phase) }
    /// Whether a restore is under way at all, from the copy being chosen to the fleet being back. A screen that
    /// can fold its own section away must not fold this one, because what is in it is the restore.
    var inFlow: Bool { phase != .idle }

    // ---------------------------------------------------------------- choosing the copy

    /// His own open panel, and no folder this app chose for him. The copies live where he put them, which from
    /// 20 October 2026 is the folder the automatic copy keeps.
    func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose a copy of your fleet"
        panel.prompt = "Open"
        panel.message = "The zip your hub gave you. Founderizer reads what is in it before it sends anything."
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        read(file)
    }

    func read(_ file: URL) {
        failure = nil; hubSaid = nil; holds = nil; receipt = nil
        do {
            copy = try ChosenCopy.read(file)
            sendID = UUID(); sendReplace = false
            phase = .chosen
        } catch {
            copy = nil
            phase = .idle
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Out of the flow without sending anything.
    func forget() {
        guard !running else { return }
        copy = nil; failure = nil; hubSaid = nil; holds = nil; receipt = nil
        sendID = UUID(); sendReplace = false
        phase = .idle
    }

    // ---------------------------------------------------------------- sending it

    /// `replace` nil means "the same command as last time", which is what Send it again is: the same id, so the
    /// hub replays its first answer instead of restoring twice.
    func send(store: FleetStore, replace: Bool? = nil) async {
        guard let copy, let database = store.state?.db, !busy else { return }
        let asked = replace ?? sendReplace
        if asked != sendReplace { sendID = UUID(); sendReplace = asked }
        phase = .sending; failure = nil; hubSaid = nil
        let hub = store.hub
        do {
            let answer = try await HubClient().restore(copy: copy.file, hub: hub, database: database,
                                                       client: store.installation, requestID: sendID,
                                                       replace: asked)
            receipt = answer
            await waitForIt(store: store, before: database, restarts: answer.restarting)
        } catch let error as HubError where error.conflict {
            await readTheConflict(store: store, database: database, said: HubError.said(error))
        } catch {
            // The hub restarts about two seconds after it answers, so a send can fail in transport with the
            // restore already accepted. Believing this error would be the one way to tell him it failed while it
            // was working, so the generation decides and not the error.
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await waitForIt(store: store, before: database, restarts: true)
        }
    }

    /// A 409 is two different things and its words are prose this app does not read, so the hub is asked again
    /// and `RestoreConflict` decides on what it answers.
    private func readTheConflict(store: FleetStore, database: String, said: String?) async {
        let now = try? await HubClient().state(at: store.hub)
        switch RestoreConflict.read(sentWith: database, now: now) {
        case .staleGeneration:
            phase = .chosen
            failure = "Your hub moved on while that was being sent. Nothing was written. Press Restore this copy "
                + "again."
            await store.refresh()
        case .holdsWork(let found):
            holds = found
            hubSaid = said
            phase = .holdsWork
        case .unknown:
            holds = nil
            hubSaid = said
            phase = .holdsWork
        }
    }

    // ---------------------------------------------------------------- waiting for it to land

    /// The hub goes away and comes back with a new `db`, and that is the only thing that says the restore landed.
    private func waitForIt(store: FleetStore, before: String, restarts: Bool) async {
        let watch = RestoreWatch(before: before, restarts: restarts)
        self.watch = watch
        began = Date()
        phase = restarts ? .restarting : .staged
        guard restarts else { return }
        await keepWatching(store: store)
    }

    /// Looks again. It is also the Check again button of a wait that gave up: nothing is sent, the hub is asked.
    func keepWatching(store: FleetStore) async {
        guard let watch else { return }
        phase = .restarting
        let hub = store.hub
        while !Task.isCancelled {
            let look: RestoreWatch.Look
            if let answer = try? await HubClient().state(at: hub) {
                look = .answered(answer.db)
            } else {
                look = .unreachable
            }
            guard store.hub == hub else { return }
            switch watch.read(look, waited: Date().timeIntervalSince(began)) {
            case .landed:
                phase = .landed
                failure = nil
                // The generation moved, so everything this app holds about the old one is gone. The store reads
                // the new fleet from here.
                await store.connect()
                return
            case .lost:
                phase = .lost
                return
            case .staged:
                phase = .staged
                return
            case .restarting:
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

// MARK: - the rows

/// The whole flow, as rows that drop into a card. System status puts them in its copy section, beside Save a
/// copy; the first-run wizard puts them in a card of their own.
struct RestoreRows: View {
    @Bindable var store: FleetStore
    @Bindable var model: RestoreModel
    /// A page of this app, for the reconnect steps. The wizard leaves it and then opens the page.
    var go: (Destination) -> Void
    /// The wizard's way on once the fleet is back. Settings > Backup passes none, because it is already the app.
    var whenDone: (() -> Void)?
    /// Whether the first row says what a restore does. The first-run wizard does, because there he is choosing
    /// between a new fleet and this one and has read nothing yet. Settings > Backup does not: a sentence under a
    /// control that says the same thing every day is wallpaper (the owner, 20 October 2026, "avoid as much text
    /// as possible everywhere!!"), and the wizard this button opens says it all again where he decides.
    var explains = true

    var body: some View {
        switch model.phase {
        case .idle: start
        case .chosen: inTheCopy
        case .holdsWork: replacing
        case .sending, .restarting, .lost, .staged: waiting
        case .landed: landed
        }
    }

    // ---------------------------------------------------------------- nothing chosen yet

    private var start: some View {
        FormRow("Put a copy back", symbol: "arrow.counterclockwise",
                // One sentence (D-2 item 29): what the copy brings back, and no second one about the address.
                detail: explains ? "Your fleet as it was when the copy was taken." : nil,
                warning: model.failure) {
            // Only while it can act: never grey (the owner: "dont show the send button if it's not clickable").
            if store.isFresh {
                Button("Restore copy") { model.choose() }
                    .buttonStyle(FleetOutlineButtonStyle())
                    .accessibilityIdentifier("restore-choose")
            }
        }
    }

    // ---------------------------------------------------------------- what is in the copy

    /// What he is about to put back, read from the copy's own manifest on this Mac. He will have several copies
    /// in one folder, so the date, the fleet and the agents are what tell them apart.
    @ViewBuilder private var inTheCopy: some View {
        if let copy = model.copy {
            FormBlock("This copy", detail: says(copy)) {
                VStack(alignment: .leading, spacing: 9) {
                    if let agents = copy.manifest.agentNames {
                        line("Agents", agents)
                    }
                    if copy.manifest.recordsSound == false {
                        line("Its records", "The hub that made it said they were not sound. It will be refused.")
                    }
                    if let vault = copy.manifest.vaultLine {
                        Text(vault).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Everything this hub holds now is replaced by it.")
                        .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let failure = model.failure {
                        Text(failure).font(FormMetrics.detail).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        if store.isFresh {
                            Button("Restore this copy") { Task { await model.send(store: store) } }
                                .buttonStyle(FleetPrimaryButtonStyle())
                                .accessibilityIdentifier("restore-send")
                        }
                        Button("Choose another") { model.choose() }.buttonStyle(FleetOutlineButtonStyle())
                        Button("Cancel") { model.forget() }.buttonStyle(FleetOutlineButtonStyle())
                            .accessibilityIdentifier("restore-cancel")
                    }
                }
            }
            .accessibilityIdentifier("restore-copy")
        }
    }

    private func says(_ copy: ChosenCopy) -> String {
        "Taken \(fleetDate(copy.manifest.made_at)) · fleet \(copy.manifest.fleet_id) · \(copy.manifest.agentsLine)"
            + " · " + ByteCountFormatter.string(fromByteCount: copy.bytes, countStyle: .binary)
    }

    // ---------------------------------------------------------------- the hub already holds a fleet

    /// The 409. This is the one irreversible press in the app, so what is there is said first, in his own terms,
    /// and the button that goes through with it is the red one at the end of the row.
    @ViewBuilder private var replacing: some View {
        if let copy = model.copy {
            FormBlock("This hub already has a fleet on it", detail: says(copy)) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(model.holds?.says ?? "Founderizer could not read what is on it, so what the copy "
                         + "replaces is not known. The hub keeps the records it puts aside, beside the new ones.")
                        .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let said = model.hubSaid {
                        Text(said).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        Button("Keep this fleet") { model.forget() }.buttonStyle(FleetOutlineButtonStyle())
                            .accessibilityIdentifier("restore-keep")
                        if store.isFresh {
                            Button("Replace it with the copy") { Task { await model.send(store: store, replace: true) } }
                                .buttonStyle(FleetDangerButtonStyle())
                                .accessibilityIdentifier("restore-replace")
                        }
                    }
                }
            }
            .accessibilityIdentifier("restore-holds")
        }
    }

    // ---------------------------------------------------------------- the wait

    @ViewBuilder private var waiting: some View {
        if model.phase == .sending || model.phase == .restarting {
            // **While the hub works, its title is the moving words** (T-13: the app's one loading look, and no spinner).
            VStack(alignment: .leading, spacing: 3) {
                ShimmeringWords(text: waitTitle, font: .systemFont(ofSize: 13, weight: .medium))
                    .accessibilityElement().accessibilityLabel(waitTitle).accessibilityAddTraits(.updatesFrequently)
                Text(waitDetail).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 12)
            .accessibilityIdentifier("restore-waiting")
        } else {
            stopped
        }
    }

    /// A wait that stopped or stands: its title and its words, and what he can do about it.
    private var stopped: some View {
        FormBlock(waitTitle, detail: waitDetail) {
            VStack(alignment: .leading, spacing: 9) {
                if model.phase == .lost {
                    HStack(spacing: 10) {
                        Button("Check again") { Task { await model.keepWatching(store: store) } }
                            .buttonStyle(FleetPrimaryButtonStyle()).accessibilityIdentifier("restore-check-again")
                        Button("Send it again") { Task { await model.send(store: store) } }
                            .buttonStyle(FleetOutlineButtonStyle())
                            .accessibilityIdentifier("restore-send-again")
                    }
                }
            }
        }
        .accessibilityIdentifier("restore-waiting")
    }

    private var waitTitle: String {
        switch model.phase {
        case .sending: "Sending the copy to your hub"
        case .restarting: "Your hub is restarting"
        case .staged: "The copy is waiting on your hub"
        case .lost: "Your hub has not come back"
        default: ""
        }
    }

    private var waitDetail: String {
        switch model.phase {
        case .sending:
            "It is checked on the hub before anything is written."
        case .restarting:
            "It has your copy. The records are only taken at a start, so the hub restarts itself now and will "
                + "not answer for a moment. That is not a failure."
        case .staged:
            "This hub does not restart itself, so the records are beside its database and its next start takes "
                + "them. Restart the hub service on that server and your fleet is back."
        case .lost:
            "The copy may be on it and waiting all the same, so look before you send it again. Sending it again "
                + "is safe — your hub answers the second send with the first answer and restores nothing twice."
        default: ""
        }
    }

    // ---------------------------------------------------------------- it landed

    /// The end of a restore is the right moment to say what he must reconnect, in the order that unblocks the
    /// fleet fastest. A restored fleet has its records and its configuration and none of the hub's own sign-ins.
    @ViewBuilder private var landed: some View {
        FormBlock("Your fleet is back", detail: landedDetail) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Read the open tasks before anything runs. They are from the moment the copy was taken, so "
                     + "a task that was open then is open again now, and its agent cannot know what the old "
                     + "server did after that.")
                    .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let whenDone {
                    Button("Open Founderizer") { whenDone() }
                        .buttonStyle(FleetPrimaryButtonStyle()).accessibilityIdentifier("restore-open-app")
                } else {
                    Button("Done") { model.forget() }
                        .buttonStyle(FleetOutlineButtonStyle()).accessibilityIdentifier("restore-done")
                }
            }
        }
        .accessibilityIdentifier("restore-landed")
        if let afterwards = model.afterwards {
            reconnect(afterwards)
        }
    }

    private var landedDetail: String {
        guard let receipt = model.receipt else { return "" }
        let written = receipt.changed.isEmpty
            ? "Its configuration was already the one on this server."
            : "\(receipt.changed.count) configuration file\(receipt.changed.count == 1 ? "" : "s") written."
        return "Your fleet \(receipt.fleet_id) · "
            + ByteCountFormatter.string(fromByteCount: receipt.records_bytes, countStyle: .binary)
            + " of records · " + written
    }

    @ViewBuilder private func reconnect(_ afterwards: RestoreAfterwards) -> some View {
        ForEach(Array(afterwards.steps.enumerated()), id: \.offset) { _, step in
            FormBlock(step.title, detail: step.detail) {
                if let label = step.place.label {
                    Button(label) { go(destination(step.place)) }.buttonStyle(FleetOutlineButtonStyle())
                }
            }
            .accessibilityIdentifier("restore-reconnect-\(step.title)")
        }
        if let nothing = afterwards.nothing {
            FormRow("What else is missing", detail: nothing)
        }
    }

    private func destination(_ place: RestoreAfterwards.Place) -> Destination {
        switch place {
        // The MCP servers have their own page of Apps (the owner's yes of 10 November 2026 to its split).
        case .apps, .nowhere: .settings(.apps)
        case .mcps: .app(.mcp)
        }
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
            Text(value).font(FormMetrics.detail).foregroundStyle(FleetStyle.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
