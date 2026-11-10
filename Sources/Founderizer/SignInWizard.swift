import AppKit
import FleetCore
import FleetMark
import SwiftUI

/// **Signing one machine's runtime in, as the wizard of adding a machine is**: one step on a page, the page after
/// it asks only what that step needs, and nothing else on the screen. The owner, 21 October 2026, after a sign-in
/// spread over three rows of a card he was also reading for other things: "wizard should be a modal like some
/// other wizards we've created like when adding a server".
///
///   1. **What it will do**, and for a change of account what it costs: that provider signs out on that machine
///      and the agent stops until the new account is in. One button starts it.
///   2. **Sign in to <provider>**: the steps on the provider's own page (`SetupSteps`), whose first link opens it in
///      his own browser and copies the code the provider printed when it prints one; under them the code to enter
///      there (Codex), or the field for the code that page gives back (Claude Code), typed into the window waiting on
///      that machine and kept nowhere. Nothing of his login passes through Founderizer. One page, as a VPS provider's
///      token page is (the owner, 10 November 2026: "applied the same way in other places, like AI provider
///      onboardings").
///   3. **Where it ended**: signed in, or what stopped it with the way to start again.
///
/// The agent's own card keeps one row while this runs, and that row opens this screen again.
///
/// **Each page is one centered step, as the setup's are** (the owner, 26 October 2026: "centering and only showing
/// the next action (dont show the send button if it's not clickable ...)"): its mark, its title and its one way on.
/// A button shows only while it can be pressed, the title moves while the machine works, and the code goes by itself
/// when it is pasted (`CodeField`).
struct SignInWizard: View {
    @Bindable var store: FleetStore
    let agent: String

    @State private var machine: MachineStatus?
    /// The sign-in this wizard is driving: the one it started, or the one already going when it opened. An older
    /// finished sign-in is history and no page of this wizard.
    @State private var mine: Int?
    @State private var code = ""
    @State private var busy = false
    /// The code went to the hub, so the page says "Signing in" until the machine's reading moves on.
    @State private var sent = false
    /// What the hub said when it would not start one. It stays until the next attempt.
    @State private var refusal: String?

    private enum Page { case start, link, code, done, failed }

    private var login: MachineLogin? {
        guard let login = machine?.login, login.id == mine else { return nil }
        return login
    }
    private var runtime: String { machine?.signInRuntime ?? store.state?.agents.first { $0.name == agent }?.runtime ?? "claude" }
    private var where_: String { machine?.machine ?? "its server" }
    private var replacing: Bool { machine?.needsSignIn != true }
    private var fresh: Bool { store.isFresh && machine?.isCurrent(at: store.state?.time ?? 0) == true }

    private var page: Page {
        guard let login else { return .start }
        switch login.state {
        case "done": return .done
        case "failed": return .failed
        default:
            // A code to paste back is the page's field from the start: its steps say to open the page first.
            guard login.signInURL != nil else { return .link }
            return login.wants_code ? .code : .link
        }
    }

    var body: some View {
        // Back to the agent stands at the page's top left, where every setup page has it.
        SetupPage {
            SetupBack { store.destination = .agentDetail(agent, .settings) }.keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("sign-in-back")
        } step: {
            Group {
                switch page {
                case .start: first
                case .link: link
                case .code: paste
                case .done: ended(signedIn: true)
                case .failed: ended(signedIn: false)
                }
            }.animation(.easeInOut(duration: 0.18), value: page)
        }
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(agent)") { await poll() }
        .onChange(of: page) { _, _ in sent = false }
        .accessibilityIdentifier("sign-in-wizard")
    }

    /// The provider's own icon, over the title of each page.
    private var mark: some View { ProviderIcon(runtime: runtime, size: SetupMetrics.mark) }

    /// The name of the page he is on. Each one says what it asks, so no page needs a line to explain itself.
    private var title: String {
        switch page {
        case .start: replacing ? "Use another \(providerName(runtime)) account" : "Sign \(agent.agentLabel) in"
        case .link, .code: "Sign in to \(providerName(runtime))"
        case .done: "\(agent.agentLabel) is signed in"
        case .failed: "The sign-in did not finish"
        }
    }

    // MARK: one — what it will do

    @ViewBuilder private var first: some View {
        if busy {
            SetupStep(title: "Starting the sign-in", waits: true) { mark }
        } else {
            SetupStep(title: title) { mark } content: {
                VStack(spacing: 18) {
                    HStack(spacing: 18) {
                        Label(where_, systemImage: "server.rack")
                        if let address = account?.address {
                            HStack(spacing: 6) {
                                ProviderIcon(runtime: runtime, size: 16)
                                Text(address).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    .foregroundStyle(FleetStyle.muted)
                    if let warning = refusal ?? (replacing ? cost : nil) { SetupWarning(warning) }
                    if store.canWrite && fresh && machine != nil {
                        Button(replacing ? "Switch account" : "Sign in") { start() }
                            .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("start-sign-in")
                    }
                }
            }
        }
    }

    /// **What it costs, said before it happens and nowhere else.** A provider starts no second sign-in while one
    /// is live, so another account means signing this one out, and that stops the agent until he is back in.
    private var cost: String {
        "\(providerName(runtime)) signs out on \(where_). \(agent.agentLabel) stops working until you have signed "
            + "in with the other account."
    }

    // MARK: two — the provider's own page

    @ViewBuilder private var link: some View {
        if let url = login?.signInURL, !sent {
            SetupStep(title: title) { mark } content: {
                VStack(spacing: SetupMetrics.gap) {
                    // What he does on the provider's page comes before the code he enters there, so the steps stand
                    // over it, and their link opens the page with the code copied.
                    SetupSteps.deviceCode(at: url).environment(\.openURL, OpenURLAction { _ in open(url); return .handled })
                    if let shown = login?.deviceCode { SetupCode(shown).accessibilityIdentifier("sign-in-device-code") }
                }
            }
        } else {
            // A wait names what it waits for (B-ONB-5, fix round 2): "Signing in to Claude Code", never "Signing in".
            SetupStep(title: sent || login?.state == "signing_in" ? "Signing in to \(providerName(runtime))"
                      : login?.isSigningOut == true ? "Signing out of \(providerName(runtime))" : "Starting the sign-in",
                      waits: true) { mark }
        }
    }

    // MARK: three — the code it gave him

    @ViewBuilder private var paste: some View {
        if sent {
            SetupStep(title: "Signing in to \(providerName(runtime))", waits: true) { mark }
        } else {
            SetupStep(title: title) { mark } content: {
                VStack(spacing: SetupMetrics.gap) {
                    // What he does on the provider's page comes before the paste, so its steps stand over the field.
                    if let url = login?.signInURL {
                        SetupSteps.signIn(at: url).environment(\.openURL, OpenURLAction { _ in open(url); return .handled })
                    }
                    CodeField(code: $code) { send() }.accessibilityIdentifier("sign-in-code")
                    if let refusal { SetupWarning(refusal) }
                }
            }
        }
    }

    // MARK: four — where it ended

    private func ended(signedIn: Bool) -> some View {
        SetupStep(title: title) { mark } content: {
            VStack(spacing: 18) {
                if signedIn {
                    // **The account is the whole of the news**: this page says what the sign-in did, and the machine's
                    // own reading of it is on the card.
                    Text(account?.address ?? providerName(runtime)).foregroundStyle(FleetStyle.muted)
                    Button("Done") { store.destination = .agentDetail(agent, .settings) }
                        .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("sign-in-done")
                } else {
                    if let why = refusal ?? login?.reason { SetupWarning(why) }
                    if store.canWrite && fresh && !busy {
                        Button("Try again") { start() }
                            .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("sign-in-again")
                    }
                }
            }
        }
    }

    private var account: AccountEmail? {
        AccountEmail(limits: store.state?.agents.first { $0.name == agent }?.accountLimits,
                     at: store.state?.time ?? 0, fresh: store.isFresh,
                     features: store.state?.ui_features ?? [])
    }

    /// The provider's own page in his own browser, with the code it printed copied for that page.
    private func open(_ url: URL) {
        if let shown = login?.deviceCode { copyMessage(shown) }
        NSWorkspace.shared.open(url)
    }

    // MARK: the hub

    private func start() {
        busy = true; refusal = nil; code = ""
        Task {
            defer { busy = false }
            switch await store.save(.machineSignin(agent: agent, runtime: runtime, replace: replacing)) {
            case .saved, .unconfirmed, .behind: break      // .behind: only with queue false
            case .refused(let words), .conflict(let words): refusal = words
            }
            await read()
            mine = machine?.login?.isOpen == true ? machine?.login?.id : mine
        }
    }

    /// Send the code, then forget it here. It is in the one request body that carries it and nowhere else.
    private func send() {
        guard !sent, let ready = MachineLogin.code(code) else { return }
        busy = true; refusal = nil; sent = true
        Task {
            defer { busy = false }
            if !(await store.command(.machineSigninCode(agent: agent, code: ready))) {
                sent = false
                refusal = store.sendError ?? "The code did not reach the hub. Paste it again."
            }
            code = ""
            await read()
        }
    }

    /// Reads this agent's machine on the rhythm of what it is doing: every two seconds while a sign-in is going
    /// on, because it is answered in seconds, and every ten otherwise.
    private func poll() async {
        machine = nil
        while !Task.isCancelled {
            await read()
            if mine == nil, machine?.login?.isOpen == true { mine = machine?.login?.id }
            do { try await store.nap(login?.isOpen == true ? 2 : 10) } catch { return }
        }
    }

    private func read() async {
        guard store.isFresh, store.state?.ui_features?.contains(MachineLogin.feature) == true,
              let database = store.state?.db else { return }
        let hub = store.hub
        guard let list = try? await HubClient().machines(hub: hub, database: database),
              !Task.isCancelled, store.hub == hub, store.state?.db == database else { return }
        machine = list.machines.first { $0.agent == agent }
    }
}
