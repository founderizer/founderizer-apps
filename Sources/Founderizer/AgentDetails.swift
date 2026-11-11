import FleetCore
import SwiftUI

extension FleetAgent {
    var roleTitle: String { role == "manager" ? "Manager" : role == "lead" ? "Lead" : "Worker" }
    /// The one line under the agent's name: its role and its provider. While its helper has not loaded a new provider,
    /// the line says that it is switching, not that the new one runs.
    func summary(switching: Bool) -> String { "\(roleTitle) · \(switching ? "Switching to " : "")\(providerName(runtime))" }
}

/// The machine behind one agent, for maintenance, in its Technical tab: versions, sign-in, network, firewall, vault
/// token, updates, the machine check and the terminal, the setup check item by item, and the helper's sessions.
struct TechnicalDetails: View {
    @Bindable var store: FleetStore
    let agent: String
    /// True where a sign-in this machine still waits for is on the face of the page already: a server's page.
    let signInOnFace: Bool
    /// The agent's Settings readings: the setup check and the names of its logins.
    private let settings: AgentSettingsModel
    private var current: FleetAgent? { store.state?.agents.first { $0.name == agent } }

    init(store: FleetStore, agent: String, signInOnFace: Bool = false) {
        self.store = store; self.agent = agent; self.signInOnFace = signInOnFace
        settings = store.settingsModel(agent: agent)
        settings.store = store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
                if store.state?.ui_features?.contains("machines") == true {
                    MachineDetails(store: store, agent: agent, signInOnFace: signInOnFace)
                        .id("\(store.hub)/\(agent)")
                }
                if let result = settings.machine?.verify { SetupCheck(result: result, logins: settings.team?.logins) }
                if let current {
                    FormSection("Helper") {
                        FormRow("Last seen") { value(fleetDate(current.last_seen)) }
                        if let client = current.client { FormRow("Client") { value(client) } }
                        if let alive = current.alive, !alive.isEmpty { FormRow("Sessions") { value(alive) } }
                    }
                }
        }.font(FormMetrics.detail)
        .task(id: "\(settings.hub)/\(settings.database)/\(agent)") {
            guard store.state?.ui_features?.contains("agent_setup") == true else { return }
            while !Task.isCancelled {
                async let team = settings.readTeam()
                async let machines: Void = settings.readMachines()
                _ = await (team, machines)
                do { try await store.nap(settings.machine?.check?.isPending == true ? 2 : 15) } catch { return }
            }
        }
    }

    private func value(_ text: String) -> some View {
        Text(text).foregroundStyle(FleetStyle.muted).multilineTextAlignment(.trailing).textSelection(.enabled)
    }
}

/// The latest machine check of an agent's setup, **item by item, as marks**.
///
/// The owner, 20 October 2026: "not even sentences, just a check or a cross, and on hover probably show the
/// detail?" Every item here answers yes or no — it passed, it failed, or nothing could say — so every item is a
/// mark, and what used to take a disclosure triangle, a state word and a second orange line is behind it: the
/// explanation, whether activation requires it, and for a login the vault's own reason and the reference.
struct SetupCheck: View {
    let result: MachineVerification
    let logins: [String: TeamLogin]?

    var body: some View {
        FormSection("Setup check", detail: "Checked \(fleetDate(result.checked_at)) · \(result.revision.prefix(8))",
                    footer: "This check uses no AI. Actual model use is reported after a real session.") {
            ForEach(result.items) { item in
                if item.kind == "login" { loginCheck(item) } else { plainCheck(item) }
            }
        }
    }

    /// One item of the check. A capability that failed and that the hub does not require is not a cross: the
    /// agent's settings do not use it, so the owner has nothing to do and the row says so without alarm.
    private func plainCheck(_ item: MachineVerification.Item) -> some View {
        let unused = item.kind == "capability" && item.state == "failed" && item.required == false
        return FormMarkRow(title: item.ref.replacingOccurrences(of: "_", with: " ").capitalized,
                           state: unused ? .unknown : Self.mark(item.state),
                           words: unused ? "Not available" : Self.words(item.state),
                           detail: said(item.detail, item),
                           whoActs: unused || item.state == "ok" ? nil : Self.onTheMachine,
                           identifier: "check-\(item.ref)")
    }

    /// One login of the profile in the check, by the catalog's name of its reference: the name is a label only and
    /// says nothing about access. Behind the mark: the vault's reason in words, the next step where the owner has
    /// one, and the reference.
    private func loginCheck(_ item: MachineVerification.Item) -> some View {
        let name = logins?[item.ref.lowercased()]?.title
        let words = Self.loginProbeWords(state: item.state, reason: item.detail)
        // Two logins without a name differ by the end of their reference.
        let title = name ?? "Login without a name …" + String(item.ref.suffix(4))
        return FormMarkRow(title: title, state: Self.mark(item.state), words: Self.words(item.state),
                           detail: said([words.fact, words.more, item.ref].compactMap { $0 }
                            .joined(separator: "\n\n"), item),
                           whoActs: item.state == "ok" ? nil : words.more == nil ? Self.onTheMachine : nil,
                           identifier: "check-login-\(item.ref)")
    }

    /// The item's own explanation, and, where activation waits on it, that it does.
    private func said(_ detail: String, _ item: MachineVerification.Item) -> String {
        guard item.required == true, item.state != "ok" else { return detail }
        return detail + "\n\nRequired for activation."
    }

    static func mark(_ state: String) -> MarkState {
        state == "ok" ? .good : state == "failed" ? .bad : .unknown
    }

    static func words(_ state: String) -> String {
        state == "ok" ? "Passed" : state == "failed" ? "Failed" : "Not verified"
    }

    /// What a cross says when putting it right is work on the machine and no button of this app takes it.
    static let onTheMachine = "This is work on the server itself. Help → Report a problem sends it, with this "
        + "check, to one of your agents."

    /// The reason of a `login` check item as a fact and, where the owner can act, the next step. The reasons are the
    /// vault's fixed probe codes (UI-API.md, "Login probe"). `not_found` says that the vault's store has no item with
    /// this reference, and `no_token` that the vault has no store that opens. `no_access` comes only from an older
    /// vault, which opened another store. A login that the vault did not test is `not probed`: it reads as not tested,
    /// never as refused. A reason that Fleet does not know gets a neutral sentence. No sentence says who may use the
    /// login.
    static func loginProbeWords(state: String, reason: String) -> (fact: String, more: String?) {
        switch (state, reason) {
        case ("ok", _):
            return ("This server's vault opened this login in the check.", nil)
        case ("failed", "no_access"):
            return ("This server's vault was not allowed to open this login.", "Check the server again.")
        case ("failed", "not_found"):
            return ("This server's vault has no login with this reference.",
                    "Check the reference in the agent's logins. Then check the server again.")
        case ("failed", "bad_format"):
            return ("The item is not a login that Founderizer can use. A login has a user name and a password.",
                    "Use another login.")
        case ("failed", "no_token"):
            return ("This server's vault has no store that opens.", "Check the vault of that server. Then check the server again.")
        case ("failed", "timeout"):
            return ("This server's vault did not finish the check in time.", "Check the server again.")
        case ("failed", "error"):
            return ("This server's vault could not open this login. It gave no more exact reason.", "Check the server again.")
        case (_, "not probed"):
            return ("This server's vault gave no answer for this login, so the check did not test it.",
                    "Check the server again. If the result stays, the vault of that server is not available or cannot test logins yet.")
        default:
            return ("The check gives no reason that Founderizer can explain.", reason.isEmpty ? nil : "Its code is “\(reason)”.")
        }
    }
}

extension AgentAttention {
    /// The status of an agent row with this problem.
    var short: String {
        switch self {
        case .staleReading: "Old reading"
        case .signIn: "Sign-in needed"
        case .updateFailed: "Update failed"
        case .checkFailed: "Check failed"
        case .restart: "Restart needed"
        }
    }
}
