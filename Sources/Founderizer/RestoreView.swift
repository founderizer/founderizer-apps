import AppKit
import FleetCore
import SwiftUI
import UniformTypeIdentifiers

/// Putting a copy of the fleet back, from the app (owner API 1.5, `POST /ui/restore`).
///
/// It is offered on Settings › Backup, beside Save a copy, because the two belong together. The end of the first
/// run asked "New fleet" or "Restore copy" until the owner's "Take it away" of 18 November 2026: he did not
/// understand that question there; its own restore page went with it. `RESTORE.md`, which the hub writes into every
/// copy, names Settings › Backup.
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
        /// Nothing chosen. The one button is Restore copy.
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
    /// command to the hub — it compares the body it recorded — so changing that flag takes a new id.
    private var sendID = UUID()
    /// `replace=yes` goes only with the press that answered the question of .holdsWork, and with its Send it again:
    /// each way back to a chosen copy turns it off with a new id (`newCommand`), because that copy can stand there for
    /// days, over work that his answer did not cover (the validator's list on R12-2, 23 November 2026). Only a copy that
    /// the hub has staged keeps both (`left`): the hub answers that command with its first answer and does nothing.
    private var sendReplace = false
    /// True from the wait of a send on (`waitForIt`) until it lands, he leaves it or Replace makes another command: its
    /// copy may be on the hub, so the answer to a resend of it is read by the generation, never as "nothing written"
    /// (the second reader's R5-1, 22 November 2026), and a generation that moved is its landing (`hubRead`).
    private var outcomeUnknown = false
    private var watch: RestoreWatch?
    /// The hub of the last send (each `send` sets it): the watch and the conflict read only it, and a change of it
    /// leaves that send (`hubMoved`; the validator's G3, the reader's R9-1, 22 November 2026). A server rebuilt at the
    /// same address also moves the generation; the state has no fleet id to tell it apart, so that case reads as the
    /// landing (a known limit).
    private var sendHub: URL?
    /// The generation that the last send named. The question of .holdsWork is about the fleet of that one (`hubRead`).
    private var sendDatabase: String?
    /// The attempt that this screen follows. A change of hub, a new copy, Cancel and a landing that the store read make
    /// a new one, and a send or a watch of an older one writes nothing more after its next wait (the reader's R9-2, 22
    /// November 2026).
    private var attempt = UUID()
    /// The upload of the send that runs now. A change of hub cancels it (`hubMoved`, which the store calls at each of
    /// its changes of hub, and this model lives in the store, so a change of tab or page ends nothing; the validator's
    /// N6 and P1, 22 November 2026): a copy whose body is cut never lands, because the hub drops a body that does not
    /// come whole and removes its folder. A known limit: once the whole body is on the first hub, which unpacks and
    /// stages it before it answers, a cancel ends only this app's wait, so the copy can still land there with nothing
    /// on this screen.
    private var upload: Task<RestoreReceipt, Error>?
    /// How long a restart may take before the wait gives up (`RestoreWatch.patience`); a test's own is short.
    var patience = RestoreWatch.patience
    private var began = Date()

    /// What this fleet must reconnect once the copy is in place.
    var afterwards: RestoreAfterwards? { copy?.afterwards }

    var busy: Bool { phase == .sending }
    /// Whether the app is in the middle of a restore and must not be walked away from quietly: its upload, or the wait
    /// for the hub's restart. The app's own restart waits for this (`AppAutoUpdate.busy`), and for nothing after it:
    /// once that wait ends, a build that waited goes in while he is away, and the app starts with the restore at rest,
    /// so the landing ("Your fleet is back" and its reconnect steps) or a wait that stands (.lost or .staged) goes
    /// unseen, with no press of his. A quit, and his own Update and Restart, drop a restore too: those are his presses.
    /// All are known limits, and no data is lost: the hub keeps a copy that it took or staged, and the Mac its file.
    var running: Bool { [.sending, .restarting].contains(phase) }
    /// Whether a restore is under way at all, from the copy being chosen to the fleet being back. A screen that
    /// can fold its own section away must not fold this one, because what is in it is the restore.
    var inFlow: Bool { phase != .idle }

    // ---------------------------------------------------------------- choosing the copy

    /// His own open panel, and no folder this app chose for him. The copies live where he put them, which from
    /// 20 October 2026 is the folder the automatic copy keeps.
    func choose() {
        let panel = NSOpenPanel()
        panel.title = String(l10n: "Choose a copy of your fleet")
        panel.prompt = String(l10n: "Open")
        panel.message = String(l10n: "The zip your hub gave you. Founderizer reads what is in it before it sends anything.")
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        read(file)
    }

    func read(_ file: URL) {
        dropSend()
        do {
            copy = try ChosenCopy.read(file)
            phase = .chosen
        } catch {
            copy = nil
            phase = .idle
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Out of the flow without sending anything: Cancel, Keep this fleet, Done. It takes nothing back from the hub,
    /// which has no route for it: a copy that it staged stays there, and its next start takes it (a known limit, which
    /// the words of .staged say, also beside Cancel: `left`).
    func forget() {
        guard !running else { return }
        dropSend()
        copy = nil
        phase = .idle
    }

    /// **He left the page** (`BackupSettings`) while a wait stood that has no Cancel (the app reader's R12-2, 23
    /// November 2026): the store keeps this model, so only this gives him the way out that the end of the page gave.
    /// .staged and .lost become a chosen copy, which has Cancel and Choose another. The watch, the hub and
    /// `outcomeUnknown` stay, so its Restore this copy looks first and names the first send's generation, and a landing
    /// shows by itself (`hubRead`). A send or a watch that runs goes on.
    ///
    /// After .lost, whose send may never have arrived, `replace` goes off with a new id, so that press asks again before
    /// it replaces anything (the validator's list); the words of .lost promise the first answer to a second send, which
    /// a new id does not get, so the line of a failed send is empty. After .staged that line has the words of .staged,
    /// and the command stays as it is: the hub has the copy and answers the same id with its first answer. A new one
    /// could end in the question of .holdsWork, whose Keep this fleet keeps nothing (the validator's N12).
    func left() {
        guard phase == .staged || phase == .lost else { return }
        failure = phase == .staged ? Self.stagedWords : nil
        if phase == .lost { newCommand() }
        phase = .chosen
    }

    /// What .staged says.
    static var stagedWords: String {
        String(l10n: "This hub does not restart itself, so the records are beside its database and its next start takes them. Restart the hub service on that server and your fleet is back.")
    }

    /// The next press is a command of its own, with `replace` off.
    private func newCommand() { sendID = UUID(); sendReplace = false }

    /// The last send is no longer this screen's: nothing of it stays, and no send or watch of it writes here again.
    private func dropSend() {
        newCommand()
        outcomeUnknown = false
        sendHub = nil; sendDatabase = nil; watch = nil; attempt = UUID()
        upload?.cancel(); upload = nil
        failure = nil; hubSaid = nil; holds = nil; receipt = nil
    }

    // ---------------------------------------------------------------- sending it

    /// `replace` nil means "the same command as last time", which is what Send it again is: the same id, so the
    /// hub replays its first answer instead of restoring twice.
    func send(store: FleetStore, replace: Bool? = nil) async {
        guard let copy, var database = store.state?.db, !busy else { return }
        let asked = replace ?? sendReplace
        // Replace it with the copy is a new command each time: from .holdsWork, also when `replace` was on already
        // (a resend with replace that got command_reused), or the same 409 would come back (the reader's round 7).
        if asked != sendReplace || (replace == true && phase == .holdsWork) {
            sendID = UUID(); sendReplace = asked; outcomeUnknown = false
        }
        let hub = store.hub
        if hubMoved(store: store) {
            return      // the app reads another hub now: this press sends nothing, and he chooses again there (R8-1)
        }
        sendHub = hub
        let mine = attempt          // after each wait below: a change of hub meanwhile ends this send (R9-2)
        phase = .sending            // busy from here: a second press while the look below waits sends nothing
        if outcomeUnknown, let watch {
            // Send it again, of a send that may have landed (the second reader's R6-1, 22 November 2026). A hub that
            // came back after the wait gave up holds the restored fleet, whose records hold no record of this id: a
            // second send would be a new command, and with `replace` a second restore, which loses the records that
            // the first one kept aside. So it looks first, as Check again does, and sends nothing when the generation
            // moved. Else it sends the first send's own generation, so that a landing during the upload gets the
            // hub's 409, which the watch reads.
            database = watch.before
            let now = try? await HubClient().state(at: hub)
            guard attempt == mine else { return }
            if let now, !now.db.isEmpty, now.db != watch.before {
                await keepWatching(store: store)
                return
            }
        }
        phase = .sending; failure = nil; hubSaid = nil
        sendDatabase = database
        do {
            let id = sendID, client = store.installation, file = copy.file
            let sending = Task {
                try await HubClient().restore(copy: file, hub: hub, database: database, client: client, requestID: id,
                                              replace: asked)
            }
            upload = sending
            let answer = try await sending.value
            guard attempt == mine else { return }
            upload = nil
            receipt = answer
            await waitForIt(store: store, hub: hub, before: database, restarts: answer.restarting)
        } catch where attempt != mine {
            return                  // the hub changed during the upload: this send is no longer this screen's
        } catch let error as HubError where error.conflict && outcomeUnknown {
            // A resend of a send that may have landed. One read of the hub decides. Only a generation that is there and
            // did not move is a hub that has no answer for this id: its 409 ("it holds work") is read as on a first
            // send, which offers Replace it with the copy (the validator's F1). Every other reading, a moved
            // generation, an empty one or none, goes to the watch, which ends in .landed or .lost, never in "nothing
            // was written" or in Replace over a restore that landed (the validator's G1, 22 November 2026).
            let now = try? await HubClient().state(at: hub)
            guard attempt == mine else { return }
            if let watch, let now, !now.db.isEmpty, now.db == watch.before {
                await readTheConflict(store: store, hub: hub, database: database, said: HubError.said(error), now: now)
            } else {
                failure = HubError.said(error) ?? error.errorDescription
                await keepWatching(store: store)
            }
        } catch let error as HubError where error.conflict {
            await readTheConflict(store: store, hub: hub, database: database, said: HubError.said(error))
        } catch let error where RestoreRefusal.wroteNothing(error) != nil && outcomeUnknown {
            // The same: its first send can have staged the copy, whose records now take the room that the head checks
            // (R5-1). The hub's words stay, and the watch decides.
            failure = RestoreRefusal.wroteNothing(error)
            await keepWatching(store: store)
        } catch let error where RestoreRefusal.wroteNothing(error) != nil {
            // The hub refused it from its head or in its check of the copy, before it wrote anything: its own words,
            // at once, and the copy stays chosen (`RestoreRefusal`), as a new command: a Replace that was refused asks
            // again (the validator's list on R12-2).
            newCommand()
            phase = .chosen
            failure = RestoreRefusal.wroteNothing(error)
        } catch {
            // The hub restarts about two seconds after it answers, so a send can fail in transport with the
            // restore already accepted. Believing this error would be the one way to tell him it failed while it
            // was working, so the generation decides and not the error.
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await waitForIt(store: store, hub: hub, before: database, restarts: true)
        }
    }

    /// A 409 is two different things and its words are prose this app does not read, so the hub is asked again
    /// and `RestoreConflict` decides on what it answers.
    /// `hub`: the hub of the send, which it reads, and not the store's of now; `read`: that hub's state when the
    /// caller read it already.
    private func readTheConflict(store: FleetStore, hub: URL, database: String, said: String?,
                                 now read: HubState? = nil) async {
        let mine = attempt
        let now: HubState?
        if let read { now = read } else { now = try? await HubClient().state(at: hub) }
        guard attempt == mine else { return }
        switch RestoreConflict.read(sentWith: database, now: now) {
        case .staleGeneration:
            // A new command with `replace` off: its next press asks again ("This hub already has a fleet on it") if
            // the generation that moved holds work, and never sends this send's `replace=yes` with another
            // generation (the reader's round 10, 22 November 2026).
            newCommand()
            phase = .chosen
            failure = String(l10n: "Your hub moved on while that was being sent. Nothing was written. Press Restore this copy again.")
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

    /// **The app reads another hub than the one of the last send** (the validator's G3 to G5, the reader's R8-1 and
    /// R9-1, 22 November 2026): that send is no longer this screen's, so the model leaves it at once, for a chosen copy
    /// with a new id, `replace` off, no watch, and no words or holdings of the first hub. He chooses again for the hub
    /// that he reads now: a press there must never carry the first hub's `replace=yes` (a Replace from .holdsWork) over
    /// a fleet that he was not asked about, nor read another fleet's generation as the landing. A new attempt ends each
    /// send and watch of the first hub at its next wait. A landing (.landed) is the first hub's with its receipt and
    /// its reconnect steps, so it goes as with Done (the app reader's R12-1, 23 November 2026). True when it left. The
    /// store calls it at each of its changes of hub, and the rows when they appear; `send` and the watch call it too.
    @discardableResult
    func hubMoved(store: FleetStore) -> Bool {
        guard phase != .idle, let sendHub, store.hub != sendHub, copy != nil else { return false }
        if phase == .landed {
            forget()
        } else {
            dropSend()
            phase = .chosen
        }
        return true
    }

    /// **The store read its hub's state** (`FleetStore.readState`, at each read), and only the last send's hub counts,
    /// with a generation that is there. While the outcome of a send is unknown, a generation other than the one that it
    /// named is its landing, in every phase and with no press: a hub that does not restart itself took the copy at its
    /// next start (.staged), or a hub came back after the wait gave up (.lost, or the copy that he left it for; the app
    /// reader's R12-2, 23 November 2026). A send on its way then ends too: it is a resend, which that hub refuses.
    /// With a known outcome, the question of .holdsWork was about the fleet of the generation that the send named: it
    /// ends for a chosen copy, as `.staleGeneration`, because Replace names the generation that the store reads now
    /// and so would replace a fleet that the question did not show (the validator's list on R12-2).
    func hubRead(_ database: String, at hub: URL) {
        guard hub == sendHub, !database.isEmpty else { return }
        if outcomeUnknown, let watch {
            guard database != watch.before else { return }
            attempt = UUID()
            upload?.cancel(); upload = nil
            land()
        } else if phase == .holdsWork, database != sendDatabase {
            newCommand()
            holds = nil; hubSaid = nil
            phase = .chosen
        }
    }

    /// The generation moved: his fleet is back.
    private func land() {
        phase = .landed
        failure = nil; hubSaid = nil; holds = nil
        outcomeUnknown = false
    }

    /// The hub goes away and comes back with a new `db`, and that is the only thing that says the restore landed.
    private func waitForIt(store: FleetStore, hub: URL, before: String, restarts: Bool) async {
        let watch = RestoreWatch(before: before, restarts: restarts, waitsAtMost: patience)
        self.watch = watch
        sendHub = hub
        outcomeUnknown = true
        began = Date()
        phase = restarts ? .restarting : .staged
        guard restarts else { return }
        await keepWatching(store: store)
    }

    /// Looks again. It is also the Check again button of a wait that gave up: nothing is sent, the hub is asked.
    func keepWatching(store: FleetStore) async {
        guard let watch else { return }
        if hubMoved(store: store) { return }      // the app reads another hub now (G3)
        let hub = sendHub ?? store.hub, mine = attempt
        phase = .restarting
        while !Task.isCancelled {
            let look: RestoreWatch.Look
            if let answer = try? await HubClient().state(at: hub) {
                look = .answered(answer.db)
            } else {
                look = .unreachable
            }
            guard attempt == mine else { return }   // a change of hub or a landing ended this watch: it writes no more (R9-2)
            if hubMoved(store: store) { return }      // the hub changed during the watch: never "restarting" for ever
            switch watch.read(look, waited: Date().timeIntervalSince(began)) {
            case .landed:
                land()
                // The generation moved, so everything this app holds about the old one is gone. The store reads
                // the new fleet from here: from the hub that it reads, which is the watched one (hubMoved), and not
                // from the typed address of `connect`, which the owner may have changed in its field since.
                await store.refresh()
                return
            case .lost:
                phase = .lost
                return
            case .staged:
                phase = .staged
                return
            case .restarting:
                try? await Task.sleep(for: .seconds(2))
                guard attempt == mine else { return }
            }
        }
    }
}

// MARK: - the rows

/// The whole flow, as rows that drop into a card: Settings › Backup puts them beside Save a copy.
struct RestoreRows: View {
    @Bindable var store: FleetStore
    @Bindable var model: RestoreModel
    /// A page of this app, for the reconnect steps.
    var go: (Destination) -> Void

    var body: some View {
        Group {
            switch model.phase {
            case .idle: start
            case .chosen: inTheCopy
            case .holdsWork: replacing
            case .sending, .restarting, .lost, .staged: waiting
            case .landed: landed
            }
        }
        // The store tells the model of each change of its hub (`FleetStore.connect`, Start again). These rows look once
        // more when they appear, for a change that no store call made (the validator's N7).
        .onAppear { model.hubMoved(store: store) }
    }

    // ---------------------------------------------------------------- nothing chosen yet

    private var start: some View {
        // No sentence under it: one that says the same thing every day is wallpaper (the owner, 20 October 2026,
        // "avoid as much text as possible everywhere!!"), and the rows this button opens say it where he decides.
        FormRow("Put a copy back", symbol: "arrow.counterclockwise", warning: model.failure) {
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
                        line(String(l10n: "Agents"), agents)
                    }
                    if copy.manifest.recordsSound == false {
                        line(String(l10n: "Its records"), String(l10n: "The hub that made it said they were not sound. It will be refused."))
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
                        if store.writesNow {
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
        String(l10n: "Taken \(fleetDate(copy.manifest.made_at)) · fleet \(copy.manifest.fleet_id) · \(copy.manifest.agentsLine) · \(ByteCountFormatter.string(fromByteCount: copy.bytes, countStyle: .binary))")
    }

    // ---------------------------------------------------------------- the hub already holds a fleet

    /// The 409. This is the one irreversible press in the app, so what is there is said first, in his own terms,
    /// and the button that goes through with it is the red one at the end of the row.
    @ViewBuilder private var replacing: some View {
        if let copy = model.copy {
            FormBlock("This hub already has a fleet on it", detail: says(copy)) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(model.holds?.says ?? String(l10n: "Founderizer could not read what is on it, so what the copy replaces is not known. The hub keeps the records it puts aside, beside the new ones."))
                        .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let said = model.hubSaid {
                        Text(said).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        Button("Keep this fleet") { model.forget() }.buttonStyle(FleetOutlineButtonStyle())
                            .accessibilityIdentifier("restore-keep")
                        if store.writesNow {
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
        case .sending: String(l10n: "Sending the copy to your hub")
        case .restarting: String(l10n: "Your hub is restarting")
        case .staged: String(l10n: "The copy is waiting on your hub")
        case .lost: String(l10n: "Your hub has not come back")
        default: ""
        }
    }

    private var waitDetail: String {
        switch model.phase {
        case .sending:
            String(l10n: "It is checked on the hub before anything is written.")
        case .restarting:
            String(l10n: "It has your copy. The records are only taken at a start, so the hub restarts itself now and will not answer for a moment. That is not a failure.")
        case .staged:
            RestoreModel.stagedWords
        case .lost:
            String(l10n: "The copy may be on it and waiting all the same, so look before you send it again. Sending it again is safe — your hub answers the second send with the first answer and restores nothing twice.")
        default: ""
        }
    }

    // ---------------------------------------------------------------- it landed

    /// The end of a restore is the right moment to say what he must reconnect, in the order that unblocks the
    /// fleet fastest. A restored fleet has its records and its configuration and none of the hub's own sign-ins.
    @ViewBuilder private var landed: some View {
        FormBlock("Your fleet is back", detail: landedDetail) {
            VStack(alignment: .leading, spacing: 9) {
                Text(String(l10n: "Read the open tasks before anything runs. They are from the moment the copy was taken, so a task that was open then is open again now, and its agent cannot know what the old server did after that."))
                    .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Done") { model.forget() }
                    .buttonStyle(FleetOutlineButtonStyle()).accessibilityIdentifier("restore-done")
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
            ? String(l10n: "Its configuration was already the one on this server.")
            : receipt.changed.count == 1 ? String(l10n: "\(receipt.changed.count) configuration file written.")
            : String(l10n: "\(receipt.changed.count) configuration files written.")
        return String(l10n: "Your fleet \(receipt.fleet_id) · \(ByteCountFormatter.string(fromByteCount: receipt.records_bytes, countStyle: .binary)) of records · \(written)")
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
