import AppKit
import FleetCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings > System status: **is my fleet connected, and is there anything I must do.**
///
/// The owner, 20 October 2026, reading his own Settings: "I only want to know if everything is connected like in
/// the System Status". So this page is that answer and the whole of it — one card, one row for each thing that can
/// be connected or not, each answered by a mark, with what stands behind it on the mark itself. Three rows that
/// were not that answer are gone: the hub's git revision, which meant nothing to him; "Agents answering 4 of 4",
/// which the rows themselves now say; and the headline that said there was no problem, which is the row he cuts.
///
/// **This Mac's own connection is the first row, and its fix is here.** It used to be a sentence and an address
/// field on Settings > General, where he met the address every day and could change it on any of them: "I have no
/// idea why we need to show the user and give it the option to change it!". The field is now what a cross carries
/// — it opens under the row when the hub does not answer, and behind the tick's own button when he asks for it —
/// so the ordinary day shows one mark, and the day the address really moves still has its one field.
///
/// **Your hub and What to do, and nothing that another section of Settings says** (the owner's map of 28 October
/// 2026, D-4: "System status (Your hub and What to do, one item per server)"). Its list of servers was the Servers
/// section's list a second time, each server's mark is on its row there, and the release it named is the first row of
/// Updates, beside it in the same sidebar.
///
/// **So the hub writes the fix and this page draws the button.** Every warning carries a `fix` line and, when it
/// is about one agent, that agent's name (owner API 1.5). This page reads those and `kind`; it parses no prose and
/// invents no advice. `FleetHealth.Warning.act` is the one place that decides what the button is, so a new warning
/// kind on the hub gets a button here, not a blank row.
///
/// **Nothing on it can disagree with anything else on it.** The marks and What to do are drawn from one `reading`,
/// replaced whole by each read, so there is no state in which the page says a thing needs him and does not say
/// which — and no state in which it keeps saying it after his hub has stopped.
struct HealthView: View {
    @Bindable var store: FleetStore
    @Environment(\.openWindow) private var openWindow
    /// The readings are the store's (`FleetStore.reading`): the page he saw last is there in its first frame when he
    /// comes back. The health is the reading a server's page draws too.
    private var reading: FleetHealth? {
        get { store.reading("servers.health") } nonmutating set { store.keep(newValue, as: "servers.health") }
    }
    /// The hub's health, read before the page first opens (`PagePrefetch`): System status and every server's page draw it.
    static let prefetch = PagePrefetch("servers.health") { try await HubClient().health(hub: $0, database: $1) }
    @State private var error: String?
    /// The page's reads: a press of Refresh while one is on its way runs one more when it ends (`RunAgain`), so the
    /// button that looks ready always acts.
    @State private var reads = RunAgain()
    /// This visit's first read has answered. Until then a first visit draws the hub's own row only, and what the read
    /// brings — the hub's figures and What to do — comes in one frame after it.
    @State private var answered = false
    @State private var copy = FleetCopyModel()
    /// He asked to change the hub address. A hub that does not answer opens it by itself.
    @State private var changingAddress = false
    /// Update fleet sends its requests.
    @State private var updating = false

    private var showsAddress: Bool { changingAddress || !store.isFresh }
    /// What the read brings is drawn: this visit's read has answered, the page has the reading from before, or no hub
    /// answers to read it from.
    private var ready: Bool { answered || !store.isFresh || reading != nil }

    var body: some View {
        FleetPage("System status") {
            connected
            if ready, let reading, !reading.warnings.isEmpty {
                // What to do from a kept reading waits a second for the read that can clear it (the loading contract, C4.4).
                // At once, from the reading kept last: these are the hub's own words about its machines, and the read
                // that starts changes them in place. Held for its second, What to do came 50 ms after the page on
                // every visit.
                toPutRight(reading)
            }
        } actions: {
            // A press while a read is on its way reads once more after it: the button stays as it is. **Only while it
            // can act** (never grey): while the hub does not answer, the window's notice has Try again.
            if store.isFresh {
                IconButton(symbol: "arrow.clockwise", words: "Refresh system status") { Task { await refresh() } }
            }
        }
        .font(FleetStyle.body).background(FleetStyle.canvas)
        // **It reads again while it shows, as every other live screen of this app does.** It read once, when
        // the page opened, and then stood there: the owner met it on 20 October 2026 saying "One thing needs
        // you" fifty-one minutes after his hub had stopped saying so — the copy warning had cleared and nothing
        // told the page. "I see that one thing needs me and there is nowhere to be seen!! come on, it is
        // frustrating! are you sure I need to do something?!". A page whose whole job is to be current was the
        // one page that was not. Fifteen seconds, the same as the other secondary reads.
        .task(id: "\(store.hub)/\(store.state?.db ?? "")") {
            while !Task.isCancelled {
                await refresh()
                do { try await store.nap(15) } catch { return }
            }
        }
    }

    // ---------------------------------------------------------------- is everything connected

    /// The whole answer, in one card for each **kind of thing that can be connected**: his hub, and a copy that is not
    /// being kept. The servers his agents run on and the release are the Servers and Updates sections' own (D-4).
    ///
    /// It was one undivided list, and the owner read it on 20 October 2026: "consider the list of checks you
    /// added, they dont make any sense, there is no organization, you put rows that are servers, a row that's
    /// your hub... it does not feel professional. Rearrange them and make it make sense!". He was right: a hub, a
    /// machine and a version number answer three different questions, and a reader of one flat column has to work
    /// out which question each row is answering before the mark beside it means anything.
    ///
    /// **A heading is not a sentence.** Each row is still one mark with everything behind it, which is the rule
    /// he set for every screen; the headings only say what the marks under them are marks of. The copy's card is
    /// there only when a copy he asked for is not kept.
    private var connected: some View {
        Group {
            FormSection("Your hub") {
                FormMarkRow(title: "Connected", state: store.isFresh ? .good : .bad, words: store.connectionLabel,
                            detail: hubDetail,
                            act: showsAddress ? nil : ("Change the address", { changingAddress = true }),
                            whoActs: showsAddress ? "The address is below." : nil,
                            identifier: "health-hub")
                if showsAddress { address }
                // A hub that answers this app and not its own status is one more thing that is not connected, so
                // it is one more row of this card, with the one thing he can do about it.
                // Not while the window's notice says the outage (`FleetStore.hubNoticeShows`; fix round 3, item 33).
                if let error, !store.hubNoticeShows {
                    FormMarkRow(title: "The hub's own status", state: .bad, words: "Cannot be read", detail: error,
                                act: ("Report a problem", { openWindow(id: FounderizerApp.reportWindow) }),
                                identifier: "health-error")
                }
                if ready, let reading { hubFacts(reading) }
            }
            // The only thing about copies that belongs on this page: one he asked for and is not getting.
            // Everything he sets, the copy he takes himself and the way back are Settings > Backup.
            if ready && copyNotKept {
                FormSection("Backup") { copyRow }
            }
        }
    }

    /// What the hub row holds: where this Mac is connected, and when it last heard back. A hub that does not
    /// answer carries the hub's own words instead, which is the only thing that says why.
    private var hubDetail: String? {
        // A Mac that was never given a hub has no address to show and no failure of a hub to tell: the address of no
        // hub stood here with "This Mac cannot find your hub" (`FleetStore.hubIsUnset`).
        if store.hubIsUnset { return nil }
        let where_ = store.hub.absoluteString
        if let trouble = store.connectionError { return "\(where_) — \(trouble)" }
        guard let last = store.lastSuccess else { return where_ }
        return "\(where_) · last refresh \(last.formatted(date: .omitted, time: .standard))"
    }

    /// The one field this page keeps, and it is not on the face of it: the hub moves about once in the life of a
    /// fleet, so the address shows when the hub does not answer and when he asks for it, and never otherwise.
    private var address: some View {
        FormRow("Hub address") {
            HStack(spacing: 8) {
                TextField(text: $store.addressText, prompt: Text(verbatim: "")) { Text("Hub address") }
                    .fieldPlaceholder("Hub address", shows: store.addressText.isEmpty).fleetField().frame(width: 230)
                    .onSubmit { Task { await connect() } }.accessibilityIdentifier("hub-address")
                Button("Connect") { Task { await connect() } }.buttonStyle(FleetOutlineButtonStyle())
                    .disabled(store.sending).accessibilityIdentifier("hub-connect")
            }
        }
    }

    /// A copy he asked for and is not getting. It is on this card and not behind Details, because the folder he
    /// chose can be renamed, unplugged or signed out of, and a copy that quietly stopped is the one failure a
    /// backup must never keep to itself. A copy that is being kept says nothing here: the hub's own `backup_old`
    /// warning is what speaks when one goes missing.
    private var copyNotKept: Bool {
        let schedule = store.copies.schedule
        return schedule.on && (!schedule.hasFolder || schedule.failure != nil)
    }

    private var copyRow: some View {
        let schedule = store.copies.schedule
        let gone = !schedule.hasFolder
        return FormMarkRow(title: "A copy of your fleet", state: .bad,
                           words: gone ? "No folder" : "Not kept",
                           detail: gone ? "Founderizer has no folder to put a copy in, so it keeps none."
                               : schedule.failure,
                           act: gone ? ("Choose a folder", { store.copies.choose() })
                               : ("Open Backup", { store.destination = .settings(.backup) }),
                           identifier: "health-copy")
    }

    // ---------------------------------------------------------------- what to do about it

    /// One block for each thing that is wrong: what the hub said, the line it wrote for putting it right, and the one
    /// button that does it.
    ///
    /// **One block for each server** (D-4 and D-2, the owner's yes of 28 October 2026: "one item per server"; "Mini's
    /// two become one"). The hub raises one warning for each fact, so one server that went quiet stood here twice —
    /// "Mini is not answering", "Mini sent no status" — each with its own "Open Mini". The warnings about one agent's
    /// server are one block now: the first one's title, what the hub said in each, and each button once.
    private func toPutRight(_ reading: FleetHealth) -> some View {
        FormSection("What to do", footer: copy.said ?? copy.failure) {
            // One block for each agent's server, each fact once (`FleetHealth.blocks`, which Report a problem draws too).
            ForEach(Array(FleetHealth.blocks(reading.warnings, manager: store.state?.agents.first(where: { $0.role == "manager" })?.name).enumerated()), id: \.offset) { _, block in
                if !block.updates.isEmpty {
                    updates(block, reading: reading)
                } else {
                    FormBlock(block.title, detail: block.detail) {
                        VStack(alignment: .leading, spacing: 9) {
                            if !block.fixes.isEmpty {
                                Text(block.fixes.joined(separator: " "))
                                    .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack(spacing: FleetSpace.actions) {
                                ForEach(Array(block.acts.enumerated()), id: \.offset) { _, act in button(for: act, reading: reading) }
                            }
                        }
                    }
                    .accessibilityIdentifier("health-warning-\(block.first.kind)")
                }
            }
        }
    }

    /// **The agents that run an older version: one table and one button** (the owner, 4 November 2026: "this should be a
    /// table and why woudl we want to update one but not the others? there should be a button to update the fleet, and
    /// simplify this!", and his yes to its mockup). The title says how many, Update fleet stands beside it, and each
    /// agent is a row of the card: its glyph and name, its role and its server, and "Update failed" where its last
    /// update failed.
    @ViewBuilder private func updates(_ block: FleetHealth.Block, reading: FleetHealth) -> some View {
        let list = store.reading("servers.list") as ServerList?
        let role = { (agent: String) in store.state?.agents.first { $0.name == agent }?.title ?? "" }
        let server = { (agent: String) in list?.server(of: agent)?.name ?? "" }
        let failures = Set(block.warnings.filter { $0.kind == "machine_failed" }.compactMap(\.agent))
        // Every column as wide as its widest entry, so the rows' columns stand at one place, and every row takes one
        // line or two at the same window width.
        let names = Self.width(block.updates.map(\.agentLabel)) + GlyphSize.inline + 8
        let roles = Self.width(block.updates.map(role))
        let servers = Self.width(block.updates.map(server))
        let failed = failures.isEmpty ? 0 : ("Update failed" as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width.rounded(.up)
        FormBlock(block.title) { EmptyView() } accessory: { button(for: .updateFleet(block.updates), reading: reading) }
            .accessibilityIdentifier("health-warning-update")
        ForEach(block.updates, id: \.self) { agent in
            let who = HStack(spacing: 8) {
                AgentGlyph(name: agent, size: GlyphSize.inline)
                Text(agent.agentLabel).foregroundStyle(FleetStyle.text)
            }.frame(width: names, alignment: .leading)
            let mark = Text(failures.contains(agent) ? "Update failed" : "").font(FormMetrics.detail).foregroundStyle(.orange)
                .frame(width: failed, alignment: .trailing)
            // One line while it fits; in a narrow window the server and the mark go on a second line under the name.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    who
                    if roles > 0 { Text(role(agent)).foregroundStyle(FleetStyle.muted).frame(width: roles, alignment: .leading) }
                    Text(server(agent)).foregroundStyle(FleetStyle.muted).frame(width: servers, alignment: .leading)
                    Spacer(minLength: 0)
                    if failed > 0 { mark }
                }.frame(minHeight: FormMetrics.row)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 12) {
                        who
                        if roles > 0 { Text(role(agent)).foregroundStyle(FleetStyle.muted) }
                    }
                    HStack(spacing: 12) {
                        Text(server(agent)).foregroundStyle(FleetStyle.muted)
                        Spacer(minLength: 0)
                        if failed > 0 { mark }
                    }.padding(.leading, GlyphSize.inline + 8)
                }.padding(.vertical, 8).frame(minHeight: FormMetrics.twoLineRow)
            }
            .lineLimit(1).font(FormMetrics.text)
            .padding(.horizontal, FormMetrics.rowInset)
            .accessibilityElement(children: .combine).accessibilityIdentifier("health-update-\(agent)")
        }
    }

    /// The widest of some words in the row's 13 points, at most 180, as on Agents.
    private static func width(_ texts: [String]) -> CGFloat {
        min(180, texts.map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width.rounded(.up) }.max() ?? 0)
    }

    /// The one button of a warning. Each is a thing this app really does: the two copy routes, the machine update
    /// command, a page of this app, or the report window — never a control that does nothing.
    @ViewBuilder private func button(for act: FleetHealth.Warning.Act, reading: FleetHealth) -> some View {
        switch act {
        case .saveCopy:
            // `isFresh`, not `canWrite`: taking the copy is a GET and confirming it goes straight to the hub,
            // neither through the outbox. A refused request waiting there must not block the one button that
            // stands between him and losing his fleet.
            // **Only while it can act** (never grey): not while the hub does not answer or keeps no copies, and while
            // the copy is being taken its place says so in moving words.
            if copy.busy {
                ShimmeringWords(text: "Saving…").accessibilityIdentifier("health-saving-copy")
            } else if store.isFresh && reading.takesCopies {
                Button(act.label) { Task { await save() } }
                    .buttonStyle(FleetPrimaryButtonStyle())
                    // Why the last copy was not recorded, in the hub's or the system's own words, where he presses again.
                    .help(copy.cause ?? "")
                    .accessibilityIdentifier("health-save-copy")
            }
        case .update(let agent):
            Button(act.label) { Task { await store.command(.machineUpdate(agent: agent)); await refresh() } }
                .buttonStyle(FleetPrimaryButtonStyle()).disabled(store.sending || !store.canWrite)
        case .updateFleet(let agents):
            // One request for each agent, one after the other; while they go, its place says so in moving words, as
            // Save copy's does. Each helper updates when it has no task, and its row leaves the table as the hub
            // takes its request.
            if updating {
                ShimmeringWords(text: "Updating…").accessibilityIdentifier("health-updating")
            } else {
                Button(act.label) {
                    updating = true
                    Task {
                        // A request the hub did not take stops the rest: its line says why, and the next press sends
                        // the ones still in the table.
                        for agent in agents { guard await store.command(.machineUpdate(agent: agent)) else { break } }
                        await refresh()
                        updating = false
                    }
                }
                .buttonStyle(FleetPrimaryButtonStyle()).disabled(store.sending || !store.canWrite)
                .accessibilityIdentifier("health-update-fleet")
            }
        case .startManager(let agent):
            Button(act.label) { Task { await store.command(.managerStart(agent: agent)); await refresh() } }
                .buttonStyle(FleetPrimaryButtonStyle()).disabled(store.sending || !store.canWrite)
                .accessibilityIdentifier("health-start-manager")
        case .openAgent(let name):
            Button(act.label) { store.destination = .agent(name) }.buttonStyle(FleetOutlineButtonStyle())
        case .openMachine(let name):
            // **The button names the page it opens** (fix round 3c): "Open Mini" opened the page called "mac-mini".
            Button("Open \(serverTitle(name))") { store.destination = .server(name) }.buttonStyle(FleetOutlineButtonStyle())
        case .tellUs:
            // Nothing on his side repairs the hub's own records or a schema step they refused. The report window
            // reads the whole fleet itself and carries this reading with it, so this is the action, not a dead end.
            Button(act.label) { openWindow(id: FounderizerApp.reportWindow) }
                .buttonStyle(FleetOutlineButtonStyle())
        }
    }

    // ---------------------------------------------------------------- the hub's own figures

    /// The three figures of the hub, in the hub's own card. They stood behind a Details fold until the owner
    /// read this page on 20 October 2026: "Also the collapsed details can't be there! ... the others dont need
    /// to be hidden". They are three short rows and they answer a question he is already on this page to ask, so
    /// hiding them bought nothing and cost a click on the day they mattered.
    ///
    /// The hub's git revision was a row here and is gone. It is a support fact and it already travels as one:
    /// Report a problem carries it with every report, under "Sent with it", where it is read before it is sent.
    @ViewBuilder private func hubFacts(_ reading: FleetHealth) -> some View {
        FormMarkRow(title: "Database",
                    state: reading.hub.integrity.result == "ok" ? .good
                        : reading.hub.integrity.result == nil ? .unknown : .bad,
                    words: reading.hub.integrity.result == "ok" ? "Sound"
                        : reading.hub.integrity.result ?? "Not checked",
                    detail: "\(bytes(reading.hub.db_bytes)), checked \(fleetDate(reading.hub.integrity.at)).",
                    act: reading.hub.integrity.result != nil && reading.hub.integrity.result != "ok"
                        ? ("Report a problem", { openWindow(id: FounderizerApp.reportWindow) }) : nil,
                    identifier: "health-database")
        FormRow("Started") { value(fleetDate(reading.hub.started_at)) }
        FormRow("Disk") { value(disk(reading.hub)) }
    }

    /// **How much of the hub's disk is used, and on which server** (the owner, 4 November 2026: "it is also not clear what
    /// Free Space means, and how much we're using, and where it is"): "11,9 of 74,8 GB used on worker-2". A hub before
    /// the load readings says its free space alone.
    private func disk(_ hub: FleetHealth.Hub) -> String {
        guard let free = hub.disk_free_bytes, let total = hub.disk_total_bytes, total > 0 else {
            return hub.disk_free_bytes.map { "\(FleetHealth.storageWords($0)) free" } ?? "Not measured"
        }
        return LoadWords.used(Double(total - min(free, total)), of: Double(total)) + (hub.machine.map { " on \($0)" } ?? "")
    }

    /// The title of the server's page that `.server(name)` opens (`ServerPage.title`): the server's own name, its
    /// machine's on a hub without servers, else the agent's name as everywhere.
    private func serverTitle(_ name: String) -> String {
        let list = store.reading("servers.list") as ServerList?
        if let server = list?.servers.first(where: { $0.name == name }) ?? list?.server(of: name) { return server.name }
        if store.state?.ui_features?.contains(Servers.feature) != true,
           let machine = (store.reading("machines") as MachineList?)?.machines.first(where: { $0.agent == name })?.machine {
            return machine
        }
        return store.state?.agents.contains { $0.name == name } == true ? name.agentLabel : name
    }

    private func value(_ text: String) -> some View { Text(text).foregroundStyle(FleetStyle.muted).textSelection(.enabled) }
    /// One decimal at most (`FleetHealth.storageWords`; fix round 3b): "829,83 GB" became "829,8 GB" 0.1 s after the
    /// page opened, when the read that followed the kept one found 30 MB less.
    private func bytes(_ value: Int64?) -> String { value.map(FleetHealth.storageWords) ?? "Not measured" }

    // ---------------------------------------------------------------- reading it

    private func connect() async {
        await store.connect()
        if store.connectionError == nil { changingAddress = false }
    }

    private func save() async {
        await copy.save(store: store)
        await refresh()
    }

    private func refresh() async {
        await reads.run { await read() }
    }

    private func read() async {
        guard store.isFresh, let database = store.state?.db else { return }
        let hub = store.hub
        let result: FleetHealth?, failure: String?
        do {
            result = try await HubClient().health(hub: hub, database: database); failure = nil
        } catch {
            // The hub writes a line for the owner beside every status it refuses with. He reads that one; a status
            // number and a sentence of ours are the same sentence to him.
            result = nil; failure = HubError.said(error) ?? "Cannot read system status. Try Refresh."
        }
        guard !Task.isCancelled, store.hub == hub, store.state?.db == database else { return }
        if let result { reading = result; error = nil } else { self.error = failure }
        answered = true
        // The servers of the agents to update, for their rows, where nothing has read them yet.
        if result?.warnings.contains(where: { FleetHealth.isUpdate($0.kind) }) == true,
           store.state?.ui_features?.contains(Servers.feature) == true,
           (store.reading("servers.list") as ServerList?) == nil,
           let list = try? await HubClient().servers(hub: hub, database: database),
           store.hub == hub, store.state?.db == database {
            store.keep(list, as: "servers.list")
        }
    }
}

/// Taking the owner's own copy of his fleet, from the one button that does it.
///
/// The hub builds the copy in memory and writes nothing on its own machine, so a copy exists only once this Mac
/// has it and has said so (`POST /ui/backups/confirm`). The order here is therefore the only honest one: take it,
/// check that what arrived is what the hub sent, let the owner say where it goes, put it there, and **only then**
/// tell the hub. A copy he did not keep never clears the warning.
@MainActor @Observable
final class FleetCopyModel {
    private(set) var busy = false
    private(set) var said: String?
    private(set) var failure: String?
    /// The system's own words for a copy the hub did not record: behind the line, never in it.
    private(set) var cause: String?

    func save(store: FleetStore) async {
        guard !busy, let database = store.state?.db else { return }
        busy = true; said = nil; failure = nil; cause = nil
        defer { busy = false }
        let client = HubClient()
        var taken: FleetCopy?
        defer { taken.map { try? FileManager.default.removeItem(at: $0.file.deletingLastPathComponent()) } }
        do {
            let copy = try await client.takeCopy(hub: store.hub, database: database)
            taken = copy
            guard let kept = Self.place(copy) else {
                said = "Nothing was saved, so your fleet still has no confirmed copy."
                return
            }
            // The copy that he keeps carries the fleet's access key, his way back after a lost Mac (`OwnerAccess`).
            try FileManager.default.moveItem(at: OwnerAccess.withKey(copy.file) ?? copy.file, to: kept)
            do {
                try await client.confirmCopy(hub: store.hub, database: database, client: store.installation,
                                             sha256: copy.sha256, bytes: copy.bytes)
                said = "Saved to \(kept.path) and confirmed with your hub."
            } catch {
                // The copy is on his disk, which is the half that matters; only the hub's record is missing.
                failure = "Saved to \(kept.path), but your hub did not record it. "
                    + "Press \(FleetHealth.Warning.Act.saveCopy.label) again."
                cause = HubError.said(error) ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Where the owner wants it. His Mac's own save panel, and nowhere this app chose for him — and the panel is
    /// where the question "what does it save?" is answered in full, because that is where he is looking.
    private static func place(_ copy: FleetCopy) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save a copy of your fleet"
        panel.prompt = "Save"
        panel.message = "Everything your hub holds: its records and your own configuration, in one file. "
            + "It cannot carry a server's vault key, so the logins its own vault made stay on that server."
        panel.nameFieldStringValue = copy.suggestedName
        panel.allowedContentTypes = [.zip]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // The panel asked him before it came back with a name that is taken; moveItem would refuse it.
        try? FileManager.default.removeItem(at: url)
        return url
    }
}
