import FleetCore
import SwiftUI

/// **Settings › General › Your profile** (owner feature `owner_profile`, owner API 1.200): one row, Name, the name that
/// the agents call the owner by. The owner, 16 November 2026: "Probably during onboarding and as a setting in general, we
/// should have something like your profile with the user name so the fleet can address them properly?", and to the
/// picture of this section above Notifications, "Mac account + Settings row": no page in the first run, because the Mac
/// gives the fleet its account's first name by itself (`FleetStore.ownerProfileTick`); this row shows the fleet's name
/// and changes it.
///
/// The field saves itself, as a role's Name does: on Return, when it loses focus and when the page goes away. **Only a
/// change that he typed is saved**: the field keeps the name that it showed when he began (`base`), so a name that the
/// Mac or his own agent gives the fleet while the field has the cursor is never taken back by a click in and out. An
/// empty field is "no name", which the Mac does not fill again.
struct OwnerProfileSection: View {
    @Bindable var store: FleetStore
    let page: OwnerProfilePage
    let reloaded: (OwnerProfilePage) -> Void
    @State private var typed = ""
    /// The name that the field showed when he began to type, until that edit ends.
    @State private var base: String?
    @State private var saving: SaveState?
    /// The save on its way: the next one waits for it, so two names reach the hub in the order he typed them.
    @State private var sending: Task<Void, Never>?
    /// The number of his newest save, until it ends: only that save changes the row.
    @State private var pending: Int?
    @State private var saves = 0
    @FocusState private var focused: Bool

    /// The fleet's name now, as the hub keeps it.
    private var kept: String { page.name?.value ?? "" }
    private var canWrite: Bool { store.isFresh && store.state?.db != nil }

    var body: some View {
        FormSection("Your profile") {
            FormRow("Name", symbol: "person", warning: saving?.failure) {
                HStack(spacing: 8) {
                    SaveMark(state: saving, retry: keep)
                    TextField(text: $typed, prompt: Text(verbatim: "")) { Text("Name") }
                        .fieldPlaceholder(String(l10n: "Name"), shows: typed.isEmpty).fleetField(focus: $focused)
                        .frame(width: 190)
                        .disabled(!canWrite)
                        .onSubmit(keep)
                        .accessibilityIdentifier("owner-name")
                }
            }
        }
        // The hub's name, while he does not type: a name that the Mac gave the fleet meanwhile shows at once.
        .task(id: kept) { if base == nil { typed = kept } }
        .onChange(of: focused) { was, now in
            if now, base == nil { base = typed }
            if was { keep() }
        }
        .onDisappear(perform: keep)
    }

    /// Saves the name as he typed it, as the hub keeps it, when it is not the one that the field showed when he began.
    /// It is read here, with the hub and its generation, before anything waits: the page going away loses none of it,
    /// and a save that waits behind another goes to the hub where he typed it.
    private func keep() {
        guard let began = base else { return }
        guard let name = OwnerProfile.keptName(typed) else {
            saving = .failed(String(l10n: "Use letters and spaces only, at most 40 characters."))
            return
        }
        guard name != OwnerProfile.keptName(began) else {
            // nothing new of his: once no save of his is on its way, the hub's name shows again
            if !focused, pending == nil { base = nil; typed = kept }
            if saving?.failure != nil { saving = nil }
            return
        }
        // the generation of this page's own reading too: a section that goes after a switch of hub saves nothing there
        guard canWrite, let db = store.state?.db, page.db == db else {
            saving = .failed(String(l10n: "This reading of your fleet is old. Refresh it before you send."))
            return
        }
        base = name
        saves += 1
        let number = saves, hub = store.hub, client = store.installation, before = sending
        pending = number
        saving = .saving
        sending = Task {
            await before?.value
            await send(name, number: number, hub: hub, database: db, client: client)
        }
    }

    /// One save. Only the newest of his saves changes the row: an older one that ends after it says nothing.
    private func send(_ name: String, number: Int, hub: URL, database: String, client: String) async {
        let profiles = OwnerProfileClient()
        do {
            _ = try await profiles.save([OwnerProfile.name: name], hub: hub, database: database, client: client)
            if let fresh = try? await profiles.read(hub: hub, database: database), store.hub == hub { reloaded(fresh) }
            guard pending == number else { return }
            pending = nil
            if !focused { base = nil; typed = name }
            saving = .saved
            Task { try? await Task.sleep(for: .seconds(3)); if saving == .saved { saving = nil } }
        } catch {
            guard pending == number else { return }
            // the hub keeps the name that it had: his stays in the field (what he types meanwhile stays as it is), and
            // Try again, or the field's next focus loss, sends it once more
            pending = nil
            if !focused { typed = name }
            base = kept
            saving = .failed(People.reason(error))
        }
    }
}
