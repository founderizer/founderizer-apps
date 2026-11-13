import FleetCore
import SwiftUI

/// One role of the fleet (plan P1, owner feature `contact_roles`), a sub-page of People: its name, whether the conversations of
/// the people who hold it run with the agent's own tools, and what the agent is told about such a person, in the
/// owner's own words. Each control saves itself, as on a person's page: the switch at once, the name and the words
/// when they lose focus (the name on Return too) and when the page goes away.
///
/// The owner writes the name as he reads it ("Key account"), and the hub keeps it as its key (`key-account`,
/// `RoleList.name(from:)`). A rename takes the people who hold the role with it, in the hub's same write, and the
/// page is then the role's under its new name (`renamed`).
struct RolePage: View {
    @Bindable var store: FleetStore
    let name: String
    let roles: RoleList?
    let back: () -> Void
    let changed: () async -> Void
    let renamed: (String) -> Void

    private enum Field { case name, prompt }

    @State private var typedName = ""
    @State private var prompt = ""
    @State private var saving: [String: SaveState] = [:]
    @State private var problem: String?
    /// The role's name in the hub after a rename, before the page follows it (`renamed`).
    @State private var key: String?
    /// The save on its way. The next one waits for it, so a rename and a change of the words reach the hub in order,
    /// each with the role's name of that moment.
    @State private var sending: Task<Void, Never>?
    @FocusState private var focus: Field?
    private let client = PeopleClient()

    private var role: RoleList.Role? { roles?.role(name) }
    private var canWrite: Bool { store.isFresh && store.state?.db != nil }

    var body: some View {
        FleetPage(People.roleWord(name), back: FleetBack("People", action: back)) {
            Group {
                if let role {
                    FormSection {
                        FormRow("Name") {
                            HStack(spacing: 8) {
                                SaveMark(state: saving["name"], retry: keepName)
                                TextField(text: $typedName, prompt: Text(verbatim: "")) { Text("Name") }
                                    .fieldPlaceholder(String(l10n: "Name"), shows: typedName.isEmpty).fleetField(focus: $focus, equals: .name).frame(width: 190)
                                    .disabled(!canWrite)
                                    .onSubmit(keepName)
                                    .accessibilityIdentifier("role-name")
                            }
                        }
                        FormRow("The agent's tools", symbol: "wrench.and.screwdriver") {
                            HStack(spacing: 8) {
                                SaveMark(state: saving["tools"], retry: { save("tools", tools: !role.tools) })
                                Toggle("", isOn: Binding(get: { role.tools }, set: { on in
                                    save("tools", tools: on)
                                })).toggleStyle(.switch).controlSize(.small).labelsHidden().disabled(!canWrite)
                                    .accessibilityLabel("The agent's tools")
                                    .accessibilityIdentifier("role-tools")
                            }
                        }
                        FormBlock("What the agent is told") {
                            // The one field look of a box of several lines (`fleetTextBox`; fix round 3, item 56).
                            TextEditor(text: $prompt).font(FleetStyle.body)
                                .fleetTextBox(focus: $focus, equals: .prompt).frame(height: 180).disabled(!canWrite)
                                .accessibilityIdentifier("role-prompt")
                        } accessory: {
                            SaveMark(state: saving["prompt"], retry: keepPrompt)
                        }
                    }
                } else if roles != nil {
                    FormSection { FormRow("This role is not there any more", symbol: "person.slash") }
                }
                if let problem {
                    Text(problem).font(FormMetrics.detail).foregroundStyle(.orange).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("role-problem")
                }
            }
        }
        .font(FleetStyle.body).foregroundStyle(FleetStyle.text)
        .task(id: name) {
            // A rename moves the page while the owner may already type in the other field: that field keeps his words.
            if focus != .name { typedName = People.roleWord(name) }
            if focus != .prompt { prompt = role?.prompt ?? "" }
        }
        .onChange(of: role?.prompt) { if focus != .prompt { prompt = role?.prompt ?? "" } }
        .onChange(of: focus) { old, _ in
            if old == .name { keepName() }
            if old == .prompt { keepPrompt() }
        }
        // Back, Esc or another page: what was typed and not saved yet goes with it.
        .onDisappear { keepName(); keepPrompt() }
    }

    /// Renames the role to what the owner typed, made into the name the hub keeps. It is read here, before anything
    /// waits, so that the page going away loses none of it. The same name writes nothing.
    private func keepName() {
        guard role != nil else { return }
        guard let made = RoleList.name(from: typedName) else {
            saving["name"] = .failed(RoleList.nameRule); problem = RoleList.nameRule
            return
        }
        guard made != (key ?? name) else { return }
        save("name", rename: made)
    }

    /// Saves the words as they are now, as the hub takes them: without the spaces at their ends. They are read here,
    /// before anything waits, so that the page going away loses none of them. Nothing changed writes nothing.
    private func keepPrompt() {
        guard let role else { return }
        let said = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard said != role.prompt else { return }
        if said.isEmpty || said.count > RoleList.promptMax {
            let why = said.isEmpty ? String(l10n: "Write what the agent is told about such a person.")
                                   : String(l10n: "That is too long: at most \(RoleList.promptMax.formatted()) characters.")
            saving["prompt"] = .failed(why); problem = why
            return
        }
        save("prompt", prompt: said)
    }

    /// One change of one field of this role, after the save before it.
    private func save(_ field: String, prompt: String? = nil, tools: Bool? = nil, rename: String? = nil) {
        let before = sending
        saving[field] = .saving; problem = nil
        sending = Task {
            await before?.value
            await send(field, prompt: prompt, tools: tools, rename: rename)
        }
    }

    /// After a rename the hub's new reading comes first, and then the page follows the role to its new name, so it
    /// never shows the role as gone.
    private func send(_ field: String, prompt: String?, tools: Bool?, rename: String?) async {
        let current = key ?? name
        guard canWrite, let db = store.state?.db, rename != current else { saving[field] = nil; return }
        do {
            _ = try await client.role(hub: store.hub, database: db, client: store.installation, name: current,
                                      prompt: prompt, tools: tools, rename: rename)
            if let rename { key = rename }
            saving[field] = .saved
            await changed()
            if let rename { renamed(rename) }
            Task {
                try? await Task.sleep(for: .seconds(2))
                if saving[field] == .saved { saving[field] = nil }
            }
        } catch {
            saving[field] = .failed(People.reason(error))
            problem = People.reason(error)
            await changed()
        }
    }
}
