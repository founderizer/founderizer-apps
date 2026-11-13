import AppKit
import FleetCore
import FleetImport
import SwiftUI
import UniformTypeIdentifiers

/// **Import** (Settings › Secrets, an outline button beside Add secret; the owner's yes of 11 November 2026 to its
/// pictures, with a Delete export file button and the two real logos): secrets from another password manager's export
/// file, Bitwarden's or 1Password's, into the fleet's vault. It is a setup's wizard, one step on a page and Back at the
/// page's top left (`SetupPage`, `SetupStep`):
///
///   1. **Where are your secrets now?** Bitwarden or 1Password, each "From an export file".
///   2. **Export your Bitwarden vault** (or 1Password data), in three numbered steps over Choose file.
///   3. **Enter the file password**, only for a Bitwarden file that has one.
///   4. **Choose what to import**: each item with a checkbox at its right, ticked except what the fleet's list has
///      already, one line for what is not imported, and Import N secrets.
///   5. **N secrets imported**, with Delete export file and Done.
///
/// The file is read in this process, once (`SecretImport`, the `FleetImport` target), with no program of a vendor, no
/// network and no file of its own. The values are in this view's state only: each is sealed to the central vault's key
/// and saved as Add secret saves one (`SecretEntryView.register`, then the vault's intake), and no agent gets it: the
/// owner gives each secret from its row. They are cleared when the import ends, at Back and when the view goes away. No
/// value reaches a log, a command argument, an environment variable or a temporary file.
struct SecretImportView: View {
    @Bindable var store: FleetStore
    /// The references that the import saved, or none: the Secrets page then reads its list again and marks them.
    let onDone: ([String]) -> Void

    private enum Page: Equatable { case source, export, password, choose, importing, done }
    @State private var page = Page.source
    @State private var vendor = SecretImport.Vendor.bitwarden
    @State private var file: URL?
    /// The file's own password, until it has opened the file or the owner went back.
    @State private var password = ""
    @State private var reading: SecretImport?
    @State private var chosen: Set<Int> = []
    /// The titles that the fleet's list had when the file was read: such a row starts unchecked. And how many secrets it
    /// had, for the room that is left in it.
    @State private var known: Set<String> = []
    /// The variable names of the list's API keys. The list takes no second key of one name (the owner, 13 November
    /// 2026), so such a row of the file cannot be ticked: Add secret replaces the value of the key that is there.
    @State private var knownKeys: Set<String> = []
    /// The references of each title that the fleet's list has, for the comparison of a value.
    @State private var references: [String: [String]] = [:]
    /// The rows of a 1Password file whose title the list has already, and whose value is not the one that the fleet
    /// holds under it ("Changed in 1Password"), as the hub's salted fingerprints say. No value leaves the Mac.
    @State private var changed: Set<Int> = []
    @State private var comparing: Task<Void, Never>?
    @State private var catalogCount = 0
    @State private var message: String?
    @State private var busy = false
    /// The central vault's key, read as the import starts and again at Import; nil while the vault does not answer.
    @State private var central: String?
    /// One row on its way into the vault: its reference, its value sealed to the vault's key, and whether the hub has
    /// registered it. A row that failed is sent again from here by Try again, under the same reference.
    private struct Pending: Equatable {
        let reference: String
        let sealed: String
        var registered = false
    }
    @State private var pending: [Int: Pending] = [:]
    @State private var saved: [Int: String] = [:]
    @State private var failed: [Int: String] = [:]
    @State private var deleted = false
    @State private var hub: URL
    @State private var database: String?

    init(store: FleetStore, onDone: @escaping ([String]) -> Void) {
        self.store = store; self.onDone = onDone
        _hub = State(initialValue: store.hub); _database = State(initialValue: store.state?.db)
    }

    /// The hub and the generation of this view, while the store still shows them and its reading is current.
    private var context: (hub: URL, db: String)? {
        guard let database, store.hub == hub, store.state?.db == database, store.isFresh, SecretEntryView.isOffered(by: store) else { return nil }
        return (hub, database)
    }

    private var room: Int { max(0, LoginSecret.maxCatalog - catalogCount) }

    var body: some View {
        SetupPage(back: { if page != .importing && page != .done { SetupBack { back() }.keyboardShortcut(.cancelAction) } }) {
            switch page {
            case .source: sourceStep
            case .export: exportStep
            case .password: passwordStep
            case .choose: chooseStep
            case .importing:
                SetupStep(title: "Importing \(Self.words(chosen.count))", waits: true) {
                    IconTile(symbol: "square.and.arrow.down", size: SetupMetrics.mark).accessibilityHidden(true)
                } content: { EmptyView() }
            case .done: doneStep
            }
        }
        .task { await readVaultKey() }
        .onDisappear { clear() }
    }

    // MARK: the steps

    private var sourceStep: some View {
        SetupStep(title: "Where are your secrets now?") {
            IconTile(symbol: "square.and.arrow.down", size: SetupMetrics.mark).accessibilityHidden(true)
        } content: {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 2), spacing: 14) {
                SetupChoice(title: "Bitwarden", line: "From an export file", mark: { VaultBrandMark(vendor: .bitwarden) },
                            choose: { open(.bitwarden) }).accessibilityIdentifier("import-bitwarden")
                SetupChoice(title: "1Password", line: "From an export file", mark: { VaultBrandMark(vendor: .onePassword) },
                            choose: { open(.onePassword) }).accessibilityIdentifier("import-1password")
            }
        }
    }

    private var exportStep: some View {
        SetupStep(title: vendor == .bitwarden ? "Export your Bitwarden vault" : "Export your 1Password data") {
            VaultBrandMark(vendor: vendor, size: SetupMetrics.mark)
        } content: {
            SetupSteps(vendor == .bitwarden ? Self.bitwardenSteps : Self.onePasswordSteps)
            if let message { SetupWarning(message) }
            Button("Choose file") { pickFile() }.buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .disabled(busy).accessibilityIdentifier("import-choose-file")
        }
    }

    private var passwordStep: some View {
        SetupStep(title: "Enter the file password") { VaultBrandMark(vendor: vendor, size: SetupMetrics.mark) } content: {
            SetupSecureField(placeholder: "File password", text: $password) { openLocked() }
                .accessibilityIdentifier("import-password")
            if let message { SetupWarning(message) }
            Button("Open") { openLocked() }.buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .disabled(busy || password.isEmpty)
        }
    }

    @ViewBuilder private var chooseStep: some View {
        if let reading {
            SetupStep(title: "Choose what to import", width: SetupMetrics.cardsWidth) { EmptyView() } content: {
                FormSection(lazy: true) {
                    if reading.rows.isEmpty { FormEmpty("Nothing to import", symbol: "key") }
                    ForEach(reading.rows) { row in pickRow(row) }
                }
                if let line = reading.skippedLine { Text(line).foregroundStyle(FleetStyle.muted) }
                if chosen.count > room {
                    SetupWarning("The list has room for \(room) more secrets. Uncheck \(chosen.count - room).")
                } else if let message { SetupWarning(message) }
                Button("Import \(Self.words(chosen.count))") { Task { await importChosen() } }
                    .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(busy || chosen.isEmpty || chosen.count > room || context == nil).accessibilityIdentifier("import-save")
            }
        }
    }

    /// One item, as a row of the Secrets list draws a secret (its kind's tile, its name, its kind), with a checkbox at its
    /// right. A row that the vaults cannot read as it is says why, in Add secret's words, and cannot be ticked. A row
    /// that the list has says "In Founderizer already", or "Changed in 1Password" when its value differs, after its
    /// kind; the vault's name stands at the right. An API key whose variable name a key of the list has cannot be
    /// ticked (`isHeldKey`): the list takes no second key of one name.
    private func pickRow(_ row: SecretImport.Row) -> some View {
        let secret = row.secret
        let kind = secret.kind == .login ? "Login" : "API key"
        let isChanged = row.problem == nil && changed.contains(row.id)
        let detail = row.problem ?? (isChanged ? kind : known.contains(secret.title) ? "\(kind) · In Founderizer already" : kind)
        return ImportRow(title: secret.title, monospaced: secret.kind == .apiKey, detail: detail, problem: row.problem != nil,
                         changed: isChanged, vault: row.vault,
                         symbol: secret.kind == .login ? "person.badge.key" : "key.horizontal",
                         on: Binding(get: { chosen.contains(row.id) },
                                     set: { on in if on { chosen.insert(row.id) } else { chosen.remove(row.id) } }),
                         locked: busy || isHeldKey(secret))
            .accessibilityIdentifier("import-row-\(row.id)")
    }

    /// An API key of the file whose variable name a key of the list has: the list takes no second one, so its row
    /// keeps its words ("In Founderizer already", or the mark of a changed value) and cannot be ticked.
    private func isHeldKey(_ secret: LoginSecret) -> Bool { secret.kind == .apiKey && knownKeys.contains(secret.title) }

    private var doneStep: some View {
        SetupStep(title: failed.isEmpty ? "\(Self.words(saved.count)) imported" : "\(saved.count) of \(chosen.count) imported") {
            IconTile(symbol: failed.isEmpty ? "checkmark" : "exclamationmark.triangle", size: SetupMetrics.mark).accessibilityHidden(true)
        } content: {
            if !failed.isEmpty {
                FormSection {
                    ForEach(failed.keys.sorted(), id: \.self) { index in
                        FormRow(reading?.rows[index].secret.title ?? "", symbol: "exclamationmark.circle", warning: failed[index])
                    }
                }
                Button("Try again") { Task { await importChosen() } }.buttonStyle(FleetOutlineButtonStyle())
                    .disabled(busy || context == nil).accessibilityIdentifier("import-retry")
            }
            if let message { SetupWarning(message) }
            Text(deleted ? "The export file is deleted." : "The export file still holds your secrets.")
                .foregroundStyle(deleted ? FleetStyle.muted : FleetStyle.text)
            HStack(spacing: 8) {
                if deleted {
                    Button("Done") { finish() }.buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("import-done")
                } else {
                    Button("Delete export file") { deleteFile() }.buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                        .disabled(busy).accessibilityIdentifier("import-delete-file")
                    Button("Done") { finish() }.buttonStyle(FleetOutlineButtonStyle()).disabled(busy)
                        .accessibilityIdentifier("import-done")
                }
            }
        }
    }

    // MARK: the steps' words

    /// What to do in each manager, in its own words (Bitwarden: Tools › Export, and Settings › Export data of Secrets
    /// Manager; 1Password: File › Export, then 1PUX or CSV). The first step names the page of the manager's own help.
    static let bitwardenSteps = ["In [Bitwarden](https://bitwarden.com/help/export-your-data/), open Tools › Export. For Secrets Manager: Settings › Export data.",
                                 "Choose .json, or .json (Encrypted) with Password protected.",
                                 "Save the file on this Mac."]
    static let onePasswordSteps = ["In [1Password](https://support.1password.com/export/), choose File › Export, then your account.",
                                   "Choose 1PUX, or CSV.",
                                   "Save the file on this Mac."]

    static func words(_ count: Int) -> String { count == 1 ? "1 secret" : "\(count) secrets" }

    // MARK: what the steps do

    private func open(_ chosenVendor: SecretImport.Vendor) { vendor = chosenVendor; message = nil; page = .export }

    private func back() {
        message = nil
        switch page {
        case .source: clear(); onDone([])
        case .export: page = .source
        case .password: password = ""; page = .export
        case .choose: comparing?.cancel(); reading = nil; chosen = []; changed = []; page = .export
        case .importing, .done: break
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = vendor == .bitwarden ? [.json] : [.commaSeparatedText, UTType(filenameExtension: "1pux") ?? .data]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        file = url
        Task { await read(url, password: nil) }
    }

    private func openLocked() {
        guard let file, !password.isEmpty else { return }
        Task { await read(file, password: password) }
    }

    /// Reads the file away from the main thread, then the fleet's list, so that a row that the list has starts unticked.
    private func read(_ url: URL, password given: String?) async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        let chosenVendor = vendor
        let result = await Task.detached { () -> Result<SecretImport, SecretImport.Failure> in
            do { return .success(try SecretImport.read(url, vendor: chosenVendor, password: given)) }
            catch let failure as SecretImport.Failure { return .failure(failure) }
            catch { return .failure(.unreadable) }
        }.value
        switch result {
        case .failure(.password(let wrong)):
            message = wrong ? SecretImport.Failure.password(wrong: true).errorDescription : nil
            page = .password
        case .failure(let failure):
            message = failure.errorDescription
            page = .export
        case .success(let made):
            password = ""
            if let context, let team = try? await HubClient().team(hub: context.hub, database: context.db), let catalog = team.logins {
                known = Set(catalog.values.map(\.name)); catalogCount = catalog.count
                knownKeys = Set(catalog.values.filter(\.isAPIKey).map(\.name))
                references = Dictionary(grouping: catalog.keys.sorted()) { catalog[$0]?.name ?? "" }
            } else {
                known = []; knownKeys = []; catalogCount = 0; references = [:]
            }
            reading = made
            chosen = Set(made.rows.filter { $0.problem == nil && !known.contains($0.secret.title) }.map(\.id))
            message = nil
            changed = []
            page = .choose
            comparing?.cancel()
            comparing = Task { await compare(made) }
        }
    }

    /// **Changed in 1Password**: for each row of a 1Password file whose title the fleet's list has already, the
    /// fingerprints of its value with the salts of each secret of that title (`GET /ui/secrets/salts`), and the hub's
    /// answer whether it holds that value (`GET /ui/secrets/same`). Only salted fingerprints go to the hub, as Add
    /// secret sends them. A row whose value has no fingerprint (shorter than 8 characters), a hub without the feature
    /// and a hub that does not answer show nothing new. The row stays unticked as every row that the list has.
    private func compare(_ made: SecretImport) async {
        guard made.vendor == .onePassword, let context,
              store.state?.ui_features?.contains(SecretImport.compareFeature) == true else { return }
        let client = HubClient()
        for row in made.rows where row.problem == nil && known.contains(row.secret.title) {
            var answers: [Bool?] = []
            for reference in references[row.secret.title] ?? [] {
                guard !Task.isCancelled else { return }
                guard let salts = try? await client.secretSalts(hub: context.hub, database: context.db, login: reference),
                      let value = try? row.secret.value(),
                      let prints = try? SecretFingerprint.of(value, salts: salts), SecretFingerprint.areValid(prints),
                      let same = try? await client.secretSame(hub: context.hub, database: context.db, login: reference,
                                                               fingerprints: prints)
                else { answers.append(nil); continue }
                answers.append(same)
            }
            guard !Task.isCancelled, reading == made else { return }
            if SecretImport.isChanged(answers) { changed.insert(row.id) }
        }
    }

    /// The central vault's key, as Add secret reads it: the key that this Mac pinned at Set up, while the hub names it.
    private func readVaultKey() async {
        guard let context, store.state?.ui_features?.contains(CentralVault.feature) == true,
              let reading = try? await VaultClient().reading(hub: context.hub, database: context.db), let fleet = reading.fleetID else {
            central = nil; return
        }
        central = reading.trusted(pin: CentralVaultPins.recipient(hub: context.hub, fleet: fleet))
    }

    /// Each chosen row once, in order, as Add secret saves one: sealed to the vault's key, registered with the hub (its
    /// fingerprints and its catalog entry), then taken by the central vault. A row that failed keeps its reference and
    /// its sealed copy, so Try again goes on from the step that failed and never makes a second secret of it.
    private func importChosen() async {
        guard !busy, let reading else { return }
        busy = true; message = nil
        defer { busy = false }
        await readVaultKey()
        guard let central, let context else {
            message = "Founderizer Vault does not answer. Nothing was sent. Try again in a moment."; return
        }
        // The room that the list has now: a row that the hub registered before is in it already.
        guard let team = try? await HubClient().team(hub: context.hub, database: context.db), let catalog = team.logins else {
            message = "The hub did not answer. Nothing was sent. Try again in a moment."; return
        }
        page = .importing
        catalogCount = catalog.count
        var left = room
        failed = [:]
        for row in reading.rows where chosen.contains(row.id) && saved[row.id] == nil {
            do {
                let secret = row.secret
                var step: Pending
                if let waiting = pending[row.id] {
                    step = waiting
                } else {
                    guard left > 0 else { failed[row.id] = "The list has \(LoginSecret.maxCatalog) secrets and takes no more."; continue }
                    let sealed: String
                    do { sealed = try AgeSeal.seal(try secret.value(), to: central) }
                    catch { failed[row.id] = "Founderizer could not seal it for the vault. Nothing was sent."; continue }
                    step = Pending(reference: "bws://\(UUID().uuidString.lowercased())", sealed: sealed)
                    pending[row.id] = step
                }
                if !step.registered {
                    try await SecretEntryView.register(step.reference, title: secret.title, kind: secret.kind, variable: secret.variable,
                                                       value: try secret.value(), hub: context.hub, database: context.db,
                                                       installation: store.installation)
                    step.registered = true; pending[row.id] = step; left -= 1
                }
                _ = try await VaultClient().intake(hub: context.hub, database: context.db, client: store.installation,
                                                   login: step.reference, ciphertext: step.sealed)
                pending[row.id] = nil
                saved[row.id] = step.reference
            } catch {
                failed[row.id] = (error as? LocalizedError)?.errorDescription ?? "The hub did not answer."
            }
        }
        page = .done
    }

    /// Deletes the export file itself, not into the Trash: it holds the owner's secrets.
    private func deleteFile() {
        guard let file else { return }
        do { try FileManager.default.removeItem(at: file); deleted = true; message = nil }
        catch { message = "Founderizer could not delete the file. Delete it in Finder, and empty the Trash." }
    }

    private func finish() {
        let references = saved.keys.sorted().compactMap { saved[$0] }
        clear()
        onDone(references)
    }

    /// No value stays when the import ends or goes: the rows, the password and the sealed copies.
    private func clear() { comparing?.cancel(); reading = nil; password = ""; chosen = []; pending = [:]; changed = [] }
}

/// One item of the file: the Secrets list's row (its kind's tile, its name, its kind) with a checkbox at its right.
private struct ImportRow: View {
    let title: String
    let monospaced: Bool
    let detail: String
    let problem: Bool
    /// "Changed in 1Password" in the detail line, after the kind and in the text's own colour (the owner's yes of 12
    /// November 2026 to its picture): "Login · Changed in 1Password".
    let changed: Bool
    /// The name of the 1Password vault that holds the item, at the right in muted text; nil for a file that names none.
    let vault: String?
    let symbol: String
    @Binding var on: Bool
    let locked: Bool
    @Environment(\.stepText) private var stepText

    var body: some View {
        let titleFont = FormMetrics.onStep(stepText, weight: .medium) ?? FormMetrics.title
        let detailFont = FormMetrics.onStep(stepText) ?? FormMetrics.detail
        HStack(spacing: 12) {
            IconTile(symbol: symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(monospaced ? titleFont.monospaced() : titleFont).foregroundStyle(FleetStyle.text).lineLimit(1)
                if changed {
                    Text("\(Text("\(detail) · ").foregroundStyle(FleetStyle.muted))\(Text("Changed in 1Password").foregroundStyle(FleetStyle.text))")
                        .font(detailFont).lineLimit(1)
                } else {
                    Text(detail).font(detailFont)
                        .foregroundStyle(problem ? Color.orange : FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.vertical, 10).multilineTextAlignment(.leading)
            // The name and its kind take the room first, so that the vault's name at the right does not fold them.
            .layoutPriority(1)
            Spacer(minLength: 12)
            if let vault {
                Text(vault).font(detailFont).foregroundStyle(FleetStyle.muted).lineLimit(1).fixedSize()
            }
            Toggle("", isOn: $on).labelsHidden().toggleStyle(FleetCheckboxStyle()).disabled(problem || locked)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, FormMetrics.rowInset).frame(minHeight: FormMetrics.twoLineRow)
        .opacity(problem ? 0.7 : 1)
    }
}

/// **The logo of a password manager on a white tile**, as `CloudMark` draws a provider's: its mark in its own colour in
/// the middle of the tile. The mark is the SVG path data of Simple Icons 16.36.0 (CC0; the colours are its own, Bitwarden
/// #175DDC and 1Password #145FE4), drawn by AppKit as a template image, so that the app bundles no image file and reads
/// no network, as `BrandMark` draws a chat app's. The logos are their owners' marks: Founderizer shows them only to name
/// the manager that a file comes from.
struct VaultBrandMark: View {
    let vendor: SecretImport.Vendor
    var size: CGFloat = 34

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: size * 0.26)
        ZStack {
            tile.fill(Color.white)
            Image(nsImage: Self.image(vendor)).renderingMode(.template).resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit).foregroundStyle(Self.color(vendor)).frame(width: size * 0.65, height: size * 0.65)
        }
        .frame(width: size, height: size).clipShape(tile).accessibilityHidden(true)
    }

    static func color(_ vendor: SecretImport.Vendor) -> Color {
        switch vendor {
        case .bitwarden: Color(red: 0x17 / 255, green: 0x5D / 255, blue: 0xDC / 255)
        case .onePassword: Color(red: 0x14 / 255, green: 0x5F / 255, blue: 0xE4 / 255)
        }
    }

    @MainActor private static func image(_ vendor: SecretImport.Vendor) -> NSImage {
        switch vendor {
        case .bitwarden: bitwarden
        case .onePassword: onePassword
        }
    }

    // simple-icons@16.36.0 icons/bitwarden.svg (SHA-256 024626ec…) and icons/1password.svg (SHA-256 7153e7c2…).
    @MainActor private static let bitwarden = image(path: "M21.722.296A.964.964 0 0 0 21.018 0H2.982a.959.959 0 0 0-.703.296.96.96 0 0 0-.297.702v12c0 .895.174 1.783.523 2.665.349.88.783 1.66 1.3 2.345.517.68 1.132 1.346 1.848 1.993a21.807 21.807 0 0 0 1.98 1.609c.605.427 1.235.83 1.893 1.212.657.381 1.125.638 1.4.772.276.134.5.241.664.311a.916.916 0 0 0 .814 0c.168-.073.389-.177.667-.311.275-.134.743-.394 1.401-.772a25.305 25.305 0 0 0 1.894-1.212A21.891 21.891 0 0 0 18.348 20c.716-.647 1.33-1.31 1.847-1.993s.949-1.463 1.3-2.345c.35-.879.524-1.767.524-2.665V1.001a.95.95 0 0 0-.297-.705zm-2.325 12.815c0 4.344-7.397 8.087-7.397 8.087V2.57h7.397v10.54z")
    @MainActor private static let onePassword = image(path: "M12 0c6.627 0 12 5.373 12 12 0 6.628-5.373 12-12 12S0 18.628 0 12C0 5.373 5.373 0 12 0m-.893 4.86c-.485 0-.727.001-.913.095a.87.87 0 0 0-.378.379c-.094.185-.095.428-.095.912v2.747c0 .12 0 .182.016.238q.02.075.065.138a1 1 0 0 0 .175.162l.695.564c.113.092.17.139.19.194a.22.22 0 0 1 0 .15c-.02.056-.077.102-.19.194l-.695.564a1 1 0 0 0-.175.162.4.4 0 0 0-.065.138 1 1 0 0 0-.016.238v6.019c0 .485 0 .728.095.913a.87.87 0 0 0 .378.378c.186.094.428.094.913.094h1.786c.485 0 .727 0 .913-.094a.87.87 0 0 0 .378-.378c.095-.185.095-.428.095-.913v-2.747c0-.12 0-.182-.016-.238a.4.4 0 0 0-.065-.138 1 1 0 0 0-.175-.162l-.695-.564c-.113-.092-.17-.138-.191-.193a.22.22 0 0 1 0-.152c.02-.055.078-.1.19-.193l.696-.564a1 1 0 0 0 .175-.162.4.4 0 0 0 .065-.138 1 1 0 0 0 .016-.238V6.246c0-.484 0-.727-.095-.912a.87.87 0 0 0-.378-.379c-.186-.094-.428-.094-.913-.094Z")

    private static func image(path: String) -> NSImage {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d=""#
            + ChatApps.spacedPath(path) + #""/></svg>"#
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage(systemSymbolName: "key.horizontal", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        return image
    }
}
