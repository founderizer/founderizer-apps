import AppKit
import FleetCore
import SwiftUI

/// The owner signs one machine's runtime in, from here (`machine_signin`).
///
/// Two clicks and one paste: **Sign in** starts the provider's own login on that machine, **Open the sign-in page**
/// opens the link the provider printed in the owner's own browser, and the code the provider gives back goes in the
/// field. The hub types it into the sign-in waiting on that machine, where the provider's own client writes the
/// credential.
///
/// What this view must never do, because the whole product rests on it: ask for a long-lived token, keep the code, or
/// send the owner anywhere but the provider's own page. The code lives in `code` until it is sent and is cleared
/// straight after; `MachineLogin.signInURL` is nil for any host that is not the provider's own, and then this view
/// offers no link at all. Grok has no sign-in here or anywhere else in Fleet.
struct MachineSignInSection: View {
    @Bindable var store: FleetStore
    let agent: String
    let reading: MachineStatus?
    let fresh: Bool
    let refresh: () async -> Void
    /// Draw the card around the rows. False where another card hosts them: the provider and account card of an
    /// agent puts them under its own account row, so a sign-in is never a card inside a card.
    var card = true
    /// The card's title, or nil on the face of a server's page: there the state row above it already names the
    /// sign-in, and the card reads as what follows that row. A server with two agents waiting names each one.
    var title: String? = "Sign-in"
    /// The page said already that this machine is not signed in, so this card says only what is new.
    var alreadySaid = false
    @State private var code = ""
    @State private var working = false
    /// The hub's own words after it refused to start a sign-in. It stays until the next attempt.
    @State private var refusal: String?
    /// He has opened the provider's page, so the step after it is the one in front of him.
    @State private var opened = false
    @FocusState private var typing: Bool

    private var login: MachineLogin? { reading?.login }
    private var runtime: String? { reading?.signInRuntime }
    /// One line, or none: a sign-in that failed goes stale against the machine's own reading of it.
    private var line: SignInLine? { reading?.signInLine(working: working, alreadySaid: alreadySaid) }

    var body: some View {
        if store.state?.ui_features?.contains(MachineLogin.feature) == true, let runtime {
            Group {
                if card { FormSection(title) { rows(runtime) } } else { rows(runtime) }
            }
            .animation(.easeInOut(duration: 0.18), value: step)
            // A sign-in that starts again starts at its first step, with nothing typed.
            .onChange(of: login?.id) { opened = false; code = "" }
        }
    }

    /// **Where the sign-in has got to, as one step.** The owner sees this one and no other: the card used to put
    /// the whole sequence on the screen at once — a line explaining it, the link, the code field — and he read
    /// three rows to find the one he was on (21 October 2026: "I want like a wizard, it has to be super smooth,
    /// one step at a time!").
    private enum Step: Equatable {
        /// No sign-in is going on. A card of its own offers to start one; hosted, the account row above does.
        case idle
        /// It is going on by itself and says where it is. Nothing to press.
        case going(String)
        /// His step: open the provider's own page, and the code to enter there when the provider printed one.
        case open(URL, String?)
        /// His step: paste back what that page gave him.
        case paste(URL)
        /// His step, where the provider takes no code back: finish on that page, with the code it printed still
        /// in front of him, because that is what he types there.
        case onThePage(URL, String?)
        case failed(String)
    }

    private var step: Step {
        if working { return .going("Working…") }
        guard let login, login.isOpen else {
            if let line, line.warn { return .failed(login?.reason ?? line.says) }
            return .idle
        }
        if let link = login.signInURL {
            if !opened { return .open(link, login.deviceCode) }
            if login.wants_code { return .paste(link) }
            return .onThePage(link, login.deviceCode)
        }
        return .going(login.summary)
    }

    /// **One row, and the wizard does the rest.** The link, the code and the steps between them are a screen of
    /// their own (`SignInWizard`), as adding a machine is: this row says where that sign-in has got to and opens
    /// it (the owner, 21 October 2026: "wizard should be a modal like some other wizards we've created").
    @ViewBuilder private func rows(_ runtime: String) -> some View {
        if card || login?.isOpen == true || line?.warn == true {
            FormRow(card ? providerName(runtime) : "Sign-in",
                    detail: line?.warn == false ? line?.says : nil,
                    warning: line?.warn == true ? line?.says : nil) {
                Button(button) { store.destination = .signIn(agent) }
                    .buttonStyle(FleetOutlineButtonStyle())
                    .disabled(!store.canWrite || !fresh || reading?.stale == true)
                    .help("Opens the sign-in: you authenticate on \(providerName(runtime))'s own page, in your own "
                          + "browser, and nothing of your login is stored by Founderizer.")
                    .accessibilityIdentifier("sign-in-\(agent)")
            }.accessibilityIdentifier("sign-in-row-\(agent)")
        }
    }

    /// What that one button says: it opens the same screen either way, so it says what opening it is for.
    private var button: String {
        if login?.isOpen == true { return "Open" }
        if login?.isFailure == true { return "Try again" }
        return reading?.needsSignIn == true ? "Sign in" : "Sign in again"
    }

    /// **What the hub said when it would not start a sign-in**, in its own words, once. The refused request leaves
    /// the outbox with it, so the window's request line does not repeat the warning.
    private func start(_ runtime: String) {
        working = true; refusal = nil
        Task {
            defer { working = false }
            // This card is the one on a server's page, where the question is "sign this machine in", not "use
            // another account": it never signs a live account out from under the agent.
            switch await store.save(.machineSignin(agent: agent, runtime: runtime, replace: false)) {
            case .saved, .unconfirmed, .behind: break      // .behind: only with queue false
            case .refused(let words), .conflict(let words): refusal = words
            }
            await refresh()
        }
    }

    /// Send the code, then forget it here. It is in the one request body that carries it and nowhere else.
    private func send() {
        guard let ready = MachineLogin.code(code) else { return }
        working = true
        Task {
            defer { working = false }
            await store.command(.machineSigninCode(agent: agent, code: ready))
            code = ""
            await refresh()
        }
    }
}
