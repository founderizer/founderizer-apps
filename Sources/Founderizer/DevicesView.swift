import FleetCore
import SwiftUI

/// Your devices (hub feature `mobile`, MOBILE-APP.md 6.5): the owner's own devices beside this Mac — today his phone,
/// which reaches the hub over the private network with its own address **and** its own key. This Mac needs no key.
///
/// The second group of Settings › Servers, with Add device on its heading (the owner's map of 28 October 2026, D-4:
/// it was a page of the main sidebar). One row for each device: what it is now in one line of words, Make a code, and
/// Remove behind one confirmation in the same row. Add device shows a code and its QR at once on a hub with
/// `device_by_code` (the owner, 3 November 2026): the phone that scans it is added with its own address, and its row
/// takes the place of the code. On an older hub Add device is two fields: the name you call it and its address;
/// Fleet makes the name that `team.json` holds. A code shows in its row and nowhere else: the hub keeps only a
/// fingerprint of it, so a repeat of the command answers with none and the row offers a new one. No code goes in a
/// note, a file or a log.
struct DevicesSection: View {
    @Bindable var store: FleetStore
    private let hub: URL
    private let database: String?

    /// The readings are the store's (`FleetStore.reading`): the devices he saw last show in the first frame when he
    /// comes back, and the read that starts then changes only what changed.
    private var reading: DeviceReading {
        get { store.reading("devices.reading") ?? .loading } nonmutating set { store.keep(newValue, as: "devices.reading") }
    }
    /// `team.json` with its version: every save of a device goes against the version that this page read.
    private var team: TeamSnapshot? {
        get { store.reading("team.snapshot") } nonmutating set { store.keep(newValue, as: "team.snapshot") }
    }
    /// When this visit began: a kept reading that its read has not answered for a second is marked as the last one.
    @State private var opened = ContinuousClock.now
    /// The new device, while the form is open.
    @State private var draft: OwnerDeviceInput?
    /// The code that this page made, in the page's own state only. A nil `code` means that the hub made one and Fleet
    /// did not get it.
    @State private var made: MadeCode?
    /// The device whose removal waits for the second click.
    @State private var confirming: String?
    @State private var problem: String?
    @State private var busy = false
    /// The device a code is being made for or that is being removed, and the words of that wait.
    @State private var working: (device: String, words: String)?
    /// The system's own words for the last read that failed: behind the row that says so, never in it.
    @State private var cause: String?

    /// The page draws this group as nothing for now (Servers, until its list's first read): its loading line waits too.
    private let held: Bool

    init(store: FleetStore, held: Bool = false) { self.store = store; self.held = held; hub = store.hub; database = store.state?.db }

    /// The devices, read before the page first opens (`PagePrefetch`).
    static let prefetch = PagePrefetch("devices.reading", feature: OwnerDevices.feature) { hub, database in
        DeviceReading.current(try await HubClient().ownerDevices(hub: hub, database: database), at: Date().timeIntervalSince1970)
    }

    private struct MadeCode: Equatable {
        /// Empty for a code for a new phone (`device_by_code`).
        let device: String
        let code: String?
        let expires: Double
        /// The devices when a code for a new phone was made: a device that is not one of them is that phone.
        var known: [String] = []
        /// The QR's one-time value (owner feature `door_calls`), which this Mac keeps to certify the phone's key.
        var bind = DeviceBinding.newBind()
    }

    /// The code for a new phone that this page made, while it shows.
    private var newCode: MadeCode? { made.flatMap { $0.device.isEmpty ? $0 : nil } }
    /// The hub adds a phone that brings a code alone, so Add device needs no fields.
    private var codeAlone: Bool { store.state?.ui_features?.contains(OwnerDevices.codeAlone) == true }

    private var now: Double { store.state?.time ?? Date().timeIntervalSince1970 }
    private var sameHub: Bool { store.hub == hub && store.state?.db == database }
    /// Not the team's version: Add device is there and pressable while the page reads, and a save reads the version
    /// first when it has none yet.
    private var canWrite: Bool { store.canWrite && sameHub && !busy }
    private var devices: [OwnerDevice] { reading.list?.devices ?? [] }
    private var limit: Int { reading.list?.limit ?? 4 }
    private var full: Bool { devices.count >= limit }

    var body: some View {
        // A group of the page, never a page: the heading, then the card, the wait or the failed row, then its one line.
        VStack(alignment: .leading, spacing: FleetSpace.block) {
            FormSection("Your devices") {
                // Before the first reading, the card waits too: no empty card and no row that blinks away.
                if reading.list != nil || draft != nil || newCode != nil {
                    ForEach(devices) { device in row(device) }
                    if draft != nil { form }
                    if let newCode { newPhone(newCode) }
                    if devices.isEmpty, draft == nil, newCode == nil, reading.list != nil {
                        FormEmpty("No devices yet", symbol: "iphone")
                    }
                } else if (reading.failure != nil || store.connectionError != nil) && !store.hubNoticeShows {
                    // While the hub does not answer nothing is read: the failed row, never "Reading the
                    // devices…"; not while the window's notice says the outage (`FleetStore.hubNoticeShows`; fix
                    // round 3, item 33), where the group keeps its heading alone.
                    FormRow("The devices are unavailable", symbol: "exclamationmark.circle",
                            warning: reading.failure.flatMap { $0.isEmpty ? nil : $0 })
                        .help(cause ?? "").accessibilityValue(cause ?? "")
                        .accessibilityIdentifier("devices-failed")
                }
            } accessory: {
                // With its plus, as Add server, Add agent and Add secret have theirs, and on the group's heading as an
                // outline capsule: the page's one white button is Add server. Only while it can act, never grey: not
                // while its form is open, not with every place taken, not while the hub cannot take a write.
                if store.canWrite && sameHub && !full && draft == nil && newCode == nil {
                    Button {
                        if codeAlone { Task { await makeNewCode() } } else { draft = OwnerDeviceInput(); problem = nil; confirming = nil }
                    } label: {
                        Label("Add device", systemImage: "plus")
                    }
                        .buttonStyle(FleetOutlineButtonStyle())
                        .help("Add a device of your own.")
                        .accessibilityIdentifier("devices-add")
                }
            }
            if !held, reading.list == nil && draft == nil && reading.failure == nil && store.connectionError == nil {
                LoadingLine(String(l10n: "Reading the devices…"))
            }
            statusLine
        }
        .font(FleetStyle.body).foregroundStyle(FleetStyle.text)
        .task { await loop() }
        .onChange(of: store.addDeviceAsked, initial: true) { _, asked in
            // A Needs-you item for his phone asked for the picture: the same step as Add device, once.
            guard asked, codeAlone, store.canWrite, sameHub, !full, draft == nil, newCode == nil else { return }
            store.addDeviceAsked = false
            Task { await makeNewCode() }
        }
    }

    // MARK: one device

    /// One device: its name, one mark for what it is now, and its two actions. Its code and its confirmation open in the
    /// row itself.
    ///
    /// **One line** (the owner's yes of 13 November 2026 to the clean Servers page): the name, with its address on hover,
    /// as a server's card has no address line either. Whether the phone reaches the hub is a yes-or-no fact, so it is
    /// the mark, and the sentence this row used to print is behind it.
    private func row(_ device: OwnerDevice) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                IconTile(symbol: device.symbol)
                Text(device.label).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(1)
                    .help(device.address)
                Spacer(minLength: 12)
                actions(device)
            }
            if confirming == device.device { confirmation(device) } else if let code = shown(device) { codeBlock(code) }
        }
        // The height of a server card's first line: its mark, its name and its actions (fix round 2).
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 10)
        .accessibilityElement(children: .contain).accessibilityIdentifier("device-\(device.device)")
    }

    private func actions(_ device: OwnerDevice) -> some View {
        let mark = device.mark(now: now)
        let canCode = canWrite && draft == nil
        // A cross is never a dead end: the one thing to press is the same Make a code this row carries, and when
        // the hub is out of reach the mark says so instead of offering a button that would do nothing.
        let act: (words: String, run: () -> Void)? = mark.state == .bad && canCode
            ? (String(l10n: "New code"), { Task { await makeCode(device) } }) : nil
        let whoActs: String? = switch mark.state {
        case .warn: String(l10n: "Nothing to do: the hub refused that one request, and the phone itself is fine.")
        case .bad where !canCode: String(l10n: "Founderizer cannot reach your hub now, so it can make no code.")
        default: nil
        }
        return HStack(spacing: 8) {
            // **The one loading look** (B-ONB-5, fix round 2): nothing for a second, then the moving words, in the row
            // that waits; it was a spinner in every row.
            if let working, working.device == device.device { LoadingLine(working.words).fixedSize() }
            // Only while it can act: not while the add form is open or a write is on its way, and never grey.
            if canCode {
                Button("New code") { Task { await makeCode(device) } }
                    .buttonStyle(FleetOutlineButtonStyle())
                    .help("One code, ten minutes, once. It gives \(device.label) its key.")
                    .accessibilityIdentifier("device-code-\(device.device)")
            }
            // Beside the one control of fixed width: that button says Make a code in one row and New code in the
            // row that is showing a code, so a mark further left would not line up with the row above it.
            StateMark(state: mark.state, words: mark.words, detail: mark.detail, act: act, whoActs: whoActs)
                .accessibilityIdentifier("device-state-\(device.device)")
            // The quiet mark asks first, in the row; the confirmation carries the red button. Hidden as Make a code is.
            if canCode {
                IconButton(symbol: "trash", words: String(l10n: "Remove \(device.label)")) {
                    confirming = device.device; made = nil; problem = nil
                }
                .accessibilityIdentifier("device-remove-\(device.device)")
            }
        }
    }

    /// Remove, behind one confirmation in the row: no dialog, and the words say what it does to the key.
    private func confirmation(_ device: OwnerDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(IconMetrics.symbol(13)).foregroundStyle(.orange)
            Text("Its key stops working at once. \(device.label) comes back only with a new code.")
                .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Cancel") { confirming = nil }.buttonStyle(FleetOutlineButtonStyle())
                .accessibilityIdentifier("device-remove-cancel")
            // Only while it can act: never grey (the owner: "dont show the send button if it's not clickable").
            if canWrite {
                Button("Remove device") { Task { await remove(device) } }.buttonStyle(FleetDangerButtonStyle())
                    .accessibilityIdentifier("device-remove-confirm")
            }
        }
    }

    /// The code of this row: the code in large text, its picture for the phone's camera, and how long it still works
    /// on the hub's clock. A code that Fleet did not get says so, because the hub cannot show it again.
    @ViewBuilder private func codeBlock(_ made: MadeCode,
                                        words: [String] = [String(l10n: "Type it in Founderizer on your phone: Settings, Add this phone.")])
        -> some View {
        if let value = made.code, made.expires > now {
            CodeAndPicture {
                VStack(alignment: .leading, spacing: 8) {
                    Text(value).font(FormMetrics.oneTimeCode)
                        .foregroundStyle(FleetStyle.text).textSelection(.enabled).accessibilityIdentifier("device-code")
                        // **On one line at every width** (fix round 2, item 101): "6PNY–" over "MTCU" at 960 points.
                        .fixedSize()
                    // How long it works is in the row's own line above, from the hub's time.
                    ForEach(words, id: \.self) { line in
                        Text(line).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                QRCodeView(text: OwnerDevices.enrollPayload(hub: hub, code: value, bind: made.bind), size: 104)
                    .accessibilityIdentifier("device-code-qr")
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(FleetStyle.canvas, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
            .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner).strokeBorder(FleetStyle.line, lineWidth: 0.5))
        } else {
            Text(made.code == nil ? "The hub made a code and keeps no copy of it, so Founderizer cannot show this one. Make a new code."
                 : "This code expired. A code works for ten minutes.")
                .font(FormMetrics.detail).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("device-code-gone")
        }
    }

    /// A code for a phone that `team.json` does not hold yet, in the card where the form was: the code, the words to
    /// scan it, how long it still works and its picture, then Cancel. The phone that brings it is added with its own
    /// address, and its new row takes the place of this block (`read`).
    private func newPhone(_ made: MadeCode) -> some View {
        VStack(alignment: .trailing, spacing: 9) {
            codeBlock(made, words: [String(l10n: "Scan with your phone."), OwnerDevices.left(made.expires, now: now)])
            Button("Cancel") { self.made = nil }.buttonStyle(FleetOutlineButtonStyle())
                .accessibilityIdentifier("device-new-cancel")
        }
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 12)
    }

    /// The code that this page has for this device, or nil.
    private func shown(_ device: OwnerDevice) -> MadeCode? {
        made.flatMap { $0.device == device.device ? $0 : nil }
    }

    // MARK: add

    /// The new device, in the card: the name you call it and its own address. Fleet makes the `team.json` name from
    /// the label, so the owner types two things and not three.
    private var form: some View {
        let value = (draft ?? OwnerDeviceInput()).named(taken: devices.map(\.device))
        let reason = value.problem(existing: devices, limit: limit)
        let typed = !(draft?.label ?? "").isEmpty || !(draft?.address ?? "").isEmpty
        let fields = HStack(spacing: 8) {
            // Their placeholders in the muted words that read, with or without the cursor (`fieldPlaceholder`; fix
            // round 3, item 55): AppKit's own grey read 2.1–2.3:1.
            TextField(text: Binding(get: { draft?.label ?? "" }, set: { draft?.label = $0 }), prompt: Text(verbatim: "")) { Text("iPhone") }
                .fieldPlaceholder("iPhone", shows: (draft?.label ?? "").isEmpty)
                .fleetField().frame(width: 150).accessibilityIdentifier("device-new-label")
            TextField(text: Binding(get: { draft?.address ?? "" }, set: { draft?.address = $0 }), prompt: Text(verbatim: "")) { Text("100.84.1.20") }
                .fieldPlaceholder("100.84.1.20", shows: (draft?.address ?? "").isEmpty)
                .fleetField().frame(width: 170).accessibilityIdentifier("device-new-address")
                .onSubmit { Task { await add() } }
        }
        let buttons = HStack(spacing: 8) {
            if busy { LoadingLine(String(l10n: "Adding \(value.label.isEmpty ? String(l10n: "the device") : value.label)…")).fixedSize() }
            Button("Cancel") { draft = nil; problem = nil }.buttonStyle(FleetOutlineButtonStyle())
            // Once the two fields make a device the hub takes: no grey button.
            if canWrite && reason == nil {
                Button("Add device") { Task { await add() } }.buttonStyle(FleetPrimaryButtonStyle())
                    .accessibilityIdentifier("device-new-save")
            }
        }
        return VStack(alignment: .leading, spacing: 9) {
            // **The fields and the buttons wrap below the card's width** (T-17, fix round 2): on one line they were
            // wider than the window at 960 pt, which cut "Cancel" and pushed the whole card past the window's edge.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { fields; Spacer(minLength: 8); buttons }
                VStack(alignment: .trailing, spacing: 9) { fields.frame(maxWidth: .infinity, alignment: .leading); buttons }
                VStack(alignment: .leading, spacing: 9) {
                    TextField(text: Binding(get: { draft?.label ?? "" }, set: { draft?.label = $0 }), prompt: Text(verbatim: "")) { Text("iPhone") }
                        .fieldPlaceholder("iPhone", shows: (draft?.label ?? "").isEmpty)
                        .fleetField().accessibilityIdentifier("device-new-label")
                    TextField(text: Binding(get: { draft?.address ?? "" }, set: { draft?.address = $0 }), prompt: Text(verbatim: "")) { Text("100.84.1.20") }
                        .fieldPlaceholder("100.84.1.20", shows: (draft?.address ?? "").isEmpty)
                        .fleetField().accessibilityIdentifier("device-new-address")
                        .onSubmit { Task { await add() } }
                    buttons.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            // Only what is wrong with what he typed (D-2): the two fields' own words say what goes in them.
            if typed, let reason {
                Text(reason).font(FormMetrics.detail).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("device-new-note")
            }
        }
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 12)
    }

    // MARK: state

    /// The devices are a reading from before this visit that the visit has not read again, **and no round of the
    /// store's has read it either** (`FleetStore.keepLive`): one that is two rounds old. A reading of the last round
    /// is no last reading, however long this visit's own read takes (10 November 2026: under load that read took more
    /// than its second, and the orange line came and went under a list that was 12 seconds old).
    private var waitsOld: Bool {
        store.readingWaits("devices.reading", since: opened)
            && (store.readingAge("devices.reading") ?? .zero) > .seconds(LiveReadings.every * 2)
    }

    /// One line at a time: the hub's own words about this page's last write first, then an old reading.
    @ViewBuilder private var statusLine: some View {
        if let problem {
            Text(problem).font(FormMetrics.detail).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled).accessibilityIdentifier("devices-problem")
        } else if !sameHub {
            Text("The hub connection changed. Open Servers again.").font(FormMetrics.detail).foregroundStyle(.orange)
        } else if (reading.isOld || waitsOld) && !store.hubNoticeShows {
            // Not before this visit's read has had a second: it takes the line away when it answers in time.
            Held(since: opened) {
                Text("Last reading \(Servers.age(reading.at, now: now)). Founderizer reads again every 15 seconds.")
                    .font(FormMetrics.detail).foregroundStyle(.orange).accessibilityIdentifier("devices-stale")
            }
        }
    }

    // MARK: the hub

    private func loop() async {
        // A failure was the last visit's: this visit reads again before it says so.
        if case .failed = reading { reading = .loading }
        while !Task.isCancelled {
            await read()
            // Every three seconds while a new phone's code shows, so its row takes the code's place at once.
            do { try await store.nap(newCode == nil ? 15 : 3) } catch { return }
        }
    }

    private func read() async {
        guard sameHub, let database else { return }
        let client = HubClient()
        let first = reading.list == nil
        do {
            let fresh = try await client.ownerDevices(hub: hub, database: database)
            let snapshot = try await client.team(hub: hub, database: database)
            if first { await store.settle(since: opened) }
            guard sameHub else { return }
            reading = .current(fresh, at: now)
            if let newCode, fresh.devices.contains(where: { !newCode.known.contains($0.device) }) { made = nil }
            team = snapshot
            await DoorCallSigning.certify(fresh.devices, store: store, hub: hub, database: database)
        } catch {
            if first { await store.settle(since: opened) }
            guard sameHub else { return }
            // The row says that the devices are unavailable; the hub's own words are its line, and the system's
            // own words for a request that got no answer are behind it.
            cause = error.localizedDescription
            reading = reading.aged ?? .failed(HubError.said(error) ?? "")
        }
    }

    private func add() async {
        if team == nil { await read() }
        let value = (draft ?? OwnerDeviceInput()).named(taken: devices.map(\.device))
        guard let sha = team?.sha256, let payload = try? value.payload(),
              value.problem(existing: devices, limit: limit) == nil else {
            problem = String(l10n: "Check the name and the address before you save.")
            return
        }
        busy = true
        defer { busy = false }
        let saved = await store.command(.ownerDevice(device: value.device, sha256: sha, delete: false), note: payload)
        if saved { draft = nil; problem = nil } else { problem = refusal(String(l10n: "Founderizer did not save the device.")) }
        await read()
    }

    private func remove(_ device: OwnerDevice) async {
        if team == nil { await read() }
        guard let sha = team?.sha256 else { problem = String(l10n: "Founderizer has no current team.json. Try again."); return }
        busy = true; working = (device.device, String(l10n: "Removing \(device.label)…"))
        defer { busy = false; working = nil }
        let removed = await store.command(.ownerDevice(device: device.device, sha256: sha, delete: true), note: "")
        if removed { confirming = nil; made = nil; problem = nil } else { problem = refusal(String(l10n: "Founderizer did not remove the device.")) }
        await read()
    }

    /// Add device on a hub with `device_by_code`: one code for a new phone, shown at once in the card.
    private func makeNewCode() async {
        busy = true
        defer { busy = false }
        confirming = nil
        let known = devices.map(\.device)
        if await store.command(.newDeviceCode) {
            let receipt = store.lastControlReceipt
            made = MadeCode(device: "", code: receipt?.code, expires: receipt?.expires ?? 0, known: known)
            if let made { DeviceBinds.remember(made.bind, until: made.expires + 3600) }
            problem = nil
        } else {
            problem = refusal(String(l10n: "The hub made no code."))
        }
    }

    private func makeCode(_ device: OwnerDevice) async {
        busy = true; working = (device.device, String(l10n: "Making a code…"))
        defer { busy = false; working = nil }
        made = nil
        confirming = nil
        if await store.command(.ownerDeviceCode(device: device.device)) {
            let receipt = store.lastControlReceipt
            if receipt?.device == device.device {
                made = MadeCode(device: device.device, code: receipt?.code, expires: receipt?.expires ?? 0)
                if let made { DeviceBinds.remember(made.bind, until: made.expires + 3600) }
            }
            problem = nil
        } else {
            problem = refusal(String(l10n: "The hub made no code."))
        }
        await read()
    }

    /// The hub's own words about a refused write, and the refused request leaves the outbox, so the window's request
    /// line does not repeat it. A request without an answer stays there, with its Retry.
    private func refusal(_ fallback: String) -> String {
        let words = store.sendError ?? store.storageError ?? fallback
        discardMine()
        return words
    }

    /// Discard the refused request of this page only. Another page's request is never discarded here.
    private func discardMine() {
        guard let pending = store.pending, pending.refusal != nil, let command = pending.command else { return }
        switch command {
        case .ownerDevice, .ownerDeviceCode, .newDeviceCode: store.discardRefused()
        default: break
        }
    }
}

/// The four states of a page that reads the hub again and again (UI-PATTERNS, "Statuses must be true"): loading, a
/// current reading, an old one, and a failed read. An old reading is never shown as current.
private enum DeviceReading: Sendable {
    case loading
    case current(OwnerDeviceList, at: Double)
    case stale(OwnerDeviceList, at: Double)
    case failed(String)

    var list: OwnerDeviceList? {
        switch self {
        case .current(let list, _), .stale(let list, _): list
        case .loading, .failed: nil
        }
    }

    var at: Double {
        switch self {
        case .current(_, let at), .stale(_, let at): at
        case .loading, .failed: 0
        }
    }

    var isOld: Bool { if case .stale = self { true } else { false } }

    /// What a failed read said.
    var failure: String? { if case .failed(let why) = self { why } else { nil } }

    /// The same reading, marked old. nil when there is none to keep.
    var aged: DeviceReading? {
        switch self {
        case .current(let list, let at), .stale(let list, let at): .stale(list, at: at)
        case .loading, .failed: nil
        }
    }
}

/// **A device's code and its picture**: side by side where the row holds both, as before, and the picture under the
/// code where it does not (fix round 2, item 101). At 960 points the row left the code too little room, and it broke
/// in two, "6PNY–" over "MTCU". The first view is the code with its words, never narrower than the code; the second is
/// the picture.
private struct CodeAndPicture: Layout {
    /// The least room between the two side by side (the stack's 18 points either side of its 8-point spacer), and the
    /// room between them one under the other.
    private let beside: CGFloat = 44, under: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2, let words = subviews.first, let picture = subviews.last else { return .zero }
        let shape = picture.sizeThatFits(.unspecified)
        let width = proposal.width ?? words.sizeThatFits(.unspecified).width + beside + shape.width
        if fitsBeside(width, words, shape) {
            let text = words.sizeThatFits(ProposedViewSize(width: width - beside - shape.width, height: nil))
            return CGSize(width: width, height: max(text.height, shape.height))
        }
        let text = words.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: text.height + under + shape.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2, let words = subviews.first, let picture = subviews.last else { return }
        let shape = picture.sizeThatFits(.unspecified)
        if fitsBeside(bounds.width, words, shape) {
            let room = ProposedViewSize(width: bounds.width - beside - shape.width, height: nil)
            words.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: room)
            picture.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(shape))
        } else {
            let room = ProposedViewSize(width: bounds.width, height: nil)
            let text = words.sizeThatFits(room)
            words.place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: room)
            picture.place(at: CGPoint(x: bounds.minX, y: bounds.minY + text.height + under), anchor: .topLeading,
                          proposal: ProposedViewSize(shape))
        }
    }

    /// Side by side, the words need the code's own width at least, and wrap in what the picture leaves.
    private func fitsBeside(_ width: CGFloat, _ words: LayoutSubview, _ picture: CGSize) -> Bool {
        words.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width + beside + picture.width <= width
    }
}
