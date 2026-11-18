import FleetCore
import SwiftUI

/// **Capabilities, one part of an agent** (the owner, 17 November 2026, of its Tools boxes under the AI provider's
/// Change: "Tools are the same regardless of the ai provider, right? maybe "capabilities" as a side menu item, with its
/// own page and a short description of what each permission is?", and his "Yes, as shown" the same day to its picture):
/// a switch for each box that the agent's AI and its server can have (`AgentBoxes`, owner API 1.216), each with one line
/// of what it allows and what it risks, and the desktop model and reasoning under Screen. They are not the same for
/// every AI: Shell goes off only where a session can be held to a fixed list of tools (Claude Code), and the browser
/// and the screen need a Mac. A box that stays on has no switch: "On", and why on its hover. Each switch saves at once,
/// through the agent's settings model, which Runs on shares; its mark and a refusal stand on the row that he switched.
struct AgentCapabilitiesPart: View {
    @Bindable var store: FleetStore
    let agent: String
    private let model: AgentSettingsModel

    init(store: FleetStore, agent: String) {
        self.store = store; self.agent = agent
        model = store.settingsModel(agent: agent)
        model.store = store
    }

    private var features: [String] { store.state?.ui_features ?? [] }
    private var time: Double { store.state?.time ?? 0 }
    private var state: FleetAgent? { store.state?.agents.first { $0.name == agent } }

    var body: some View {
        FleetPage(AgentTab.capabilities.heading) {
            if let line = model.line {
                FormSection { rows(line) }
            } else if model.readError != nil && store.pageReadingIsOld(failedSince: model.readFailedSince)
                        || store.connectionError != nil {
                // Said once, by the window's notice, while it says the outage (`FleetStore.hubNoticeShows`). One break of
                // the hub says nothing, as on Runs on: "Reading the settings…" stays until then.
                if !store.hubNoticeShows { FormSection { FormRow("Settings not read", warning: model.readError) } }
            } else {
                LoadingLine(String(l10n: "Reading the settings…"))
            }
        }
        .task(id: "\(model.hub)/\(model.database)/\(agent)") {
            model.visited()
            let start = ContinuousClock.now
            while !Task.isCancelled {
                async let team = model.readTeam(since: start)
                async let machines: Void = model.readMachines()
                _ = await (team, machines)
                // Again in 3 s after a read of team.json that failed, as Runs on: its row goes as soon as the hub is back.
                do { try await store.nap(model.readFailedSince == nil ? 15 : 3) } catch { return }
            }
        }
    }

    @ViewBuilder private func rows(_ line: ReportingLine) -> some View {
        let boxes = AgentBoxes.of(line)
        // What it has in effect: an entry with no Tools list reads `can: []` and has the shell and the web (`on`).
        let can = if case .capabilities(let value)? = model.shown(.capabilities) { value } else {
            boxes.on ?? line.can ?? state?.can ?? []
        }
        ForEach(boxes.offered, id: \.self) { box in
            boxRow(box, can: can, boxes: boxes)
            // **The desktop model under Screen** (his picture), while Screen is on: desktop tasks run on it.
            if box == "screen", can.contains(box), !boxes.idle.contains(box), features.contains("screen_model"), line.screen != nil,
               let machine = model.machine {
                Group { screenRows(line, machine) }.padding(.leading, FormMetrics.markColumn + FormMetrics.markGap)
            }
        }
        if model.machine?.settings_pending == true {
            FormRow("Waiting for \(agent.agentLabel) to load the new settings.", symbol: "clock")
        }
    }

    /// One box: its name, its line, and a switch, or "On" where a write cannot turn it off. A box that it holds and
    /// that does nothing for it now (a browser on a Linux server, a screen with the Shell box off) says so in its line.
    private func boxRow(_ box: String, can: [String], boxes: AgentBoxes) -> some View {
        let title = Self.title(box)
        let stays = boxes.stays_on.contains(box), idle = boxes.idle.contains(box)
        let switched = model.switchedBox
        return FormRow(title, symbol: Self.symbol(box),
                       detail: idle ? String(l10n: "Does nothing for this agent now.") : words(box, stays: stays),
                       warning: switched == box ? model.states[.capabilities]?.failure : nil) {
            if stays {
                Text("On").foregroundStyle(FleetStyle.muted).help(staysOn)
                    .accessibilityIdentifier("settings-can-\(box)")
            } else {
                HStack(spacing: 10) {
                    if switched == box { SaveMark(state: model.states[.capabilities]) { model.retry(.capabilities, store: store) } }
                    Toggle(title, isOn: Binding(get: { can.contains(box) }, set: { on in
                        model.switchedBox = box
                        // A box that stays on goes with every write: the hub refuses a list without it.
                        var next = can.filter { $0 != box }
                        if on { next.append(box) }
                        next += boxes.stays_on.filter { !next.contains($0) }
                        model.save(.capabilities(next), store: store)
                    })).toggleStyle(.switch).controlSize(.small).labelsHidden()
                        // With the Shell box on, Web off removes no tool: its shell reaches the web (the hub's words).
                        .help(box == "web" && can.contains("shell") ? String(l10n: "Its shell reaches the web too.") : "")
                        .accessibilityIdentifier("settings-can-\(box)")
                }
            }
        }
    }

    /// Where the agent runs, as its lines name it: its server's name.
    private var server: String {
        model.team?.members.first { $0.agent == agent }?.placement?.machine ?? model.machine?.machine ?? String(l10n: "its server")
    }

    /// **One line of what the box allows, and what it risks** (his "a short description of what each permission is").
    private func words(_ box: String, stays: Bool) -> String? {
        switch box {
        case "shell":
            stays ? String(l10n: "Runs commands and changes files on \(server).")
                : String(l10n: "Runs commands and changes files on \(server). Keep it off for an agent that reads messages from strangers.")
        case "web": String(l10n: "Uses the web. A web page can contain instructions from strangers.")
        case "browser": String(l10n: "Uses Chrome on \(server). It can act on each site where it is signed in.")
        case "screen": String(l10n: "Uses the mouse and keyboard of \(server). It can do all that a person at that Mac can do.")
        default: nil
        }
    }

    /// Why Shell stays on: the hub refuses Shell off for a runtime with no closed version (and for the manager, which
    /// has no Capabilities).
    private var staysOn: String { String(l10n: "This AI cannot work with its Shell box off.") }

    static func title(_ box: String) -> String {
        switch box {
        case "shell": String(l10n: "Shell")
        case "web": String(l10n: "Web")
        case "browser": String(l10n: "Browser")
        case "screen": String(l10n: "Screen")
        default: box.capitalized
        }
    }

    static func symbol(_ box: String) -> String {
        switch box {
        case "shell": "apple.terminal"
        case "web": "globe"
        case "browser": "macwindow"
        case "screen": "display"
        default: "circle"
        }
    }

    // MARK: Desktop model

    /// The model and reasoning of desktop tasks, which the desktop's runtime runs with its own settings (it was two rows
    /// under the AI provider's Change).
    @ViewBuilder private func screenRows(_ line: ReportingLine, _ machine: MachineStatus) -> some View {
        let screen = if case .screen(let value)? = model.shown(.screen) { value } else { line.screen ?? ScreenSettingsInput() }
        let models = machine.screen_models
        let gets = ScreenSettingsInput(model: screen.model ?? followed(ScreenSettingsInput()).model, effort: screen.effort)
        let supported = models?.isCurrent(at: time) == true && models?.supportsScreen(gets, at: time) == true
        if let models, models.ok {
            FormRow("Desktop model", detail: line.reported_screen_model.map { String(l10n: "Last used: \($0.model ?? String(l10n: "not reported")), \(fleetDate($0.at))") },
                    warning: model.states[.screen]?.failure) {
                HStack(spacing: 10) {
                    SaveMark(state: model.states[.screen]) { model.retry(.screen, store: store) }
                    FleetSelect("Desktop model", selection: Binding(get: { screen.model ?? "" }, set: { name in
                        let next = name.isEmpty ? nil : name
                        if next != screen.model {
                            model.save(.screen(ScreenSettingsInput(model: next, effort: models.effort(screen.effort, with: next))), store: store)
                        }
                    }), options: AgentSetupView.modelOptions(models, current: screen.model,
                                                            default: followed(ScreenSettingsInput(model: nil, effort: screen.effort)).model))
                        .accessibilityIdentifier("setup-screen-model")
                }
            }
            FormRow("Desktop reasoning", warning: supported || screen == ScreenSettingsInput() ? nil :
                        String(l10n: "Check this server, or select an available desktop model and reasoning.")) {
                FleetSelect("Desktop reasoning", selection: Binding(get: { screen.effort ?? "" }, set: { level in
                    let next = level.isEmpty ? nil : level
                    if next != screen.effort { model.save(.screen(ScreenSettingsInput(model: screen.model, effort: next)), store: store) }
                }), options: AgentSetupView.effortOptions(models, model: screen.model ?? followed(ScreenSettingsInput()).model,
                                                         current: screen.effort,
                                                         default: followed(ScreenSettingsInput(model: screen.model, effort: nil)).effort))
                    .accessibilityIdentifier("setup-screen-effort")
            }
        } else {
            FormRow("Desktop model", warning: models?.error ?? String(l10n: "Check this server to read its desktop model options.")) {
                value(screen.model ?? automaticChoice)
            }
            FormRow("Desktop reasoning") { value(screen.effort.map(reasoningName) ?? automaticChoice) }
        }
    }

    /// The model and reasoning that a desktop task gets with these of its own: the Codex row of the owner's defaults where
    /// the agent's server takes them (`DefaultModels.session`).
    private func followed(_ screen: ScreenSettingsInput) -> ModelDefault {
        DefaultModels.session(model.team?.default_models["codex"], model: screen.model, effort: screen.effort,
                              machine: model.machine?.screen_models, runtime: "codex",
                              takes: model.machine?.features?.contains(DefaultModels.feature) == true)
    }

    private func value(_ text: String) -> some View {
        Text(text).foregroundStyle(FleetStyle.muted).multilineTextAlignment(.trailing).textSelection(.enabled)
    }
}
