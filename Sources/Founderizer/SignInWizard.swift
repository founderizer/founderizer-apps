import AppKit
import FleetCore
import FleetMark
import FleetOwnerAPI
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
    /// The provider that the page was opened for, when that is not the server's own choice (`Destination.signIn`):
    /// Codex of the screen tasks of an agent on Claude Code, from the error row of a task's thread or from the page of
    /// its Mac (`ScreenSignIn`).
    var asked: String? = nil

    @State private var machine: MachineStatus?
    /// This view's own mark for the page that it tells the store (`WizardPages.tell`, `gone`).
    @State private var placeMark = UUID()
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
    /// The page by its fixed name (`AppPlace`, `setup_state`'s `place`), with no default: a new page needs a name.
    private static func placeName(_ page: Page) -> AppPlace.SignInPage {
        switch page {
        case .start: .start
        case .link: .link
        case .code: .code
        case .done: .done
        case .failed: .failed
        }
    }

    private var login: MachineLogin? {
        guard let login = machine?.login, login.id == mine else { return nil }
        return login
    }
    /// The agent's own provider, as its row of the fleet says.
    private var ownRuntime: String? { store.state?.agents.first { $0.name == agent }?.runtime }
    /// **The provider that this page signs in**: the one of the sign-in that runs, else the one that the page was opened
    /// for (`asked`), else the server's own choice. With the server's choice alone, the page could sign in only the
    /// agent's own provider, and a Codex that its server reported signed out had no sign-in in the app.
    private var runtime: String { login?.runtime ?? asked ?? machine?.signInRuntime ?? ownRuntime ?? "claude" }
    /// The page signs in a provider that is not the agent's own, because it was opened for that provider or a sign-in
    /// of it runs: its words name the provider and not the agent, who is signed in, and it shows no account, because
    /// the agent's reading has only its own. A plain opening with no such sign-in is never this, also while a change of
    /// the agent's provider is under way and the server's own choice is still the old one.
    private var named: Bool { (login?.runtime ?? asked).map { $0 != ownRuntime } ?? false }
    private var where_: String { machine?.machine ?? String(l10n: "its server") }
    /// A sign-in of a provider that is signed in changes its account. Of a provider that is not the agent's own, only
    /// the server's word that it is signed in says so, from a reading that is current, as the row that leads here
    /// reads it (`RuntimeErrorLine`): before that word, with none and with an old one, the page offers its sign-in.
    private var replacing: Bool {
        if named { return fresh && machine?.signedIn(runtime) == true }
        return machine?.needsSignIn != true
    }
    private var fresh: Bool { store.isFresh && machine?.isCurrent(at: store.state?.time ?? 0) == true }

    private var page: Page {
        // A provider that is not the agent's own, and that its server says is signed in, has nothing to do here: the
        // page says so, also after a sign-in of it that failed. "Use another account" there would say that the agent
        // stops, which is true only of its own, and "Try again" would sign the provider out first.
        if named, replacing, login?.isOpen != true { return .done }
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
            SetupBack { leave() }.keyboardShortcut(.cancelAction)
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
        .onChange(of: page, initial: true) { _, now in
            store.wizardPages.tell(signIn: .init(agent: agent, page: Self.placeName(now)), by: placeMark)
        }
        .onDisappear { store.wizardPages.gone(placeMark) }
        .accessibilityIdentifier("sign-in-wizard")
    }

    /// The provider's own icon, over the title of each page.
    private var mark: some View { ProviderIcon(runtime: runtime, size: SetupMetrics.mark) }

    /// The name of the page he is on. Each one says what it asks, so no page needs a line to explain itself.
    private var title: String {
        switch page {
        // A provider that is not the agent's own is named: "Sign Solo in" would say that the agent is signed out.
        case .start: replacing ? String(l10n: "Use another \(providerName(runtime)) account")
            : named ? String(l10n: "Sign in to \(providerName(runtime))") : String(l10n: "Sign \(agent.agentLabel) in")
        case .link, .code: String(l10n: "Sign in to \(providerName(runtime))")
        case .done: String(l10n: "\(named ? providerName(runtime) : agent.agentLabel) is signed in")
        case .failed: String(l10n: "The sign-in did not finish")
        }
    }

    // MARK: one — what it will do

    @ViewBuilder private var first: some View {
        if busy {
            SetupStep(title: String(l10n: "Starting the sign-in"), waits: true) { mark }
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
        // A sign-out stops every agent of that sign-in, not only this one (`sign_in_shared`).
        let others = (machine?.sign_in_shared?[runtime] ?? []).filter { $0 != agent }
        if !others.isEmpty {
            let names = ([agent] + others).map(\.agentLabel).formatted(.list(type: .and))
            if let server = machine?.machine {
                return String(l10n: "\(providerName(runtime)) signs out on \(server). \(names) stop working until you have signed in with the other account.")
            }
            return String(l10n: "\(providerName(runtime)) signs out on its server. \(names) stop working until you have signed in with the other account.")
        }
        if let server = machine?.machine {
            return String(l10n: "\(providerName(runtime)) signs out on \(server). \(agent.agentLabel) stops working until you have signed in with the other account.")
        }
        return String(l10n: "\(providerName(runtime)) signs out on its server. \(agent.agentLabel) stops working until you have signed in with the other account.")
    }

    // MARK: two — the provider's own page

    @ViewBuilder private var link: some View {
        if let url = login?.signInURL, !sent {
            SetupStep(title: title) { mark } content: {
                VStack(spacing: SetupMetrics.gap) {
                    // What he does on the provider's page comes before the code he enters there, so the steps stand
                    // over it, and their link opens the page with the code copied.
                    SetupSteps.deviceCode(at: url).environment(\.openURL, OpenURLAction { _ in open(url); return .handled })
                    if let shown = login?.deviceCode { SetupCode(shown, id: "sign-in-device-code") }
                }
            }
        } else {
            // A wait names what it waits for (B-ONB-5, fix round 2): "Signing in to Claude Code", never "Signing in".
            SetupStep(title: sent || login?.state == "signing_in" ? String(l10n: "Signing in to \(providerName(runtime))")
                      : login?.isSigningOut == true ? String(l10n: "Signing out of \(providerName(runtime))") : String(l10n: "Starting the sign-in"),
                      waits: true) { mark }
        }
    }

    // MARK: three — the code it gave him

    @ViewBuilder private var paste: some View {
        if sent {
            SetupStep(title: String(l10n: "Signing in to \(providerName(runtime))"), waits: true) { mark }
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
                    Text(named ? where_ : account?.address ?? providerName(runtime)).foregroundStyle(FleetStyle.muted)
                    Button("Done") { leave() }
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

    /// **Where Back and Done go**: the agent's settings, where its sign-in row is. From a page that was opened for a
    /// named provider, the page that he came from, which is the task whose row sent him here or the page of that Mac;
    /// when no page that he left can open any more, the agent's settings too.
    private func leave() {
        if asked != nil { store.goBack() }
        if case .signIn(agent, asked) = store.destination { store.destination = .agentDetail(agent, .settings) }
    }

    /// The agent's own account, on a sign-in of the agent's own provider. The account of another provider of its server
    /// is not in the agent's reading, so its page names the provider alone.
    private var account: AccountEmail? {
        guard !named else { return nil }
        return AccountEmail(limits: store.state?.agents.first { $0.name == agent }?.accountLimits,
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
            // Never a sign-out of a provider that is not the agent's own: each agent of that server's user has it.
            switch await store.save(.machineSignin(agent: agent, runtime: runtime, replace: replacing && !named)) {
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
                refusal = store.sendError ?? String(l10n: "The code did not reach the hub. Paste it again.")
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
        // The store's own reading has it too: the row that sent him here (`RuntimeErrorLine`) and each other page read
        // that one, and after his sign-in they said "signed out" until their next read.
        store.keep(list, as: "machines")
    }
}
