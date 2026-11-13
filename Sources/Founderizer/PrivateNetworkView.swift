import AppKit
import FleetCore
import Observation
import SwiftUI

/// Your private network: this Mac, and the one credential that puts every machine of your fleet on it.
///
/// **It is asked for while a machine is being set up, and never otherwise.** The owner, 20 October 2026: "Same
/// issue for the private network section. What is even that? The mac should NOT be on the network anyway..so why
/// show that? this is just meant to control the fleet and set it up, make sure all servers are connected... but
/// the constant links to open tailscale and enter id and secret... like, why???" He was right about the screen
/// even where he was wrong about the Mac: the credential has one job, at one moment — this Mac mints a key with
/// it for a machine that is joining — so it belongs at that moment and nowhere else. Settings had a standing page
/// about Tailscale with its links, its fields and the answer to a question nobody was asking; that page is gone.
/// "Are my machines connected" is answered where it is asked, by a mark for each machine on System status and by
/// each server's own page.
///
/// What is left is these rows, in the two places that really are setting a machine up: the first run, and an
/// install that finds a machine which is not on the network yet. Each row asks for one thing and says what
/// becomes of it.
@MainActor @Observable
final class PrivateNetworkModel {
    /// This Mac, as Tailscale answers for it.
    private(set) var mac: MacNetwork.Standing?
    /// The client id of the credential this Mac holds, which is safe to show; nil when it holds none. The secret is
    /// never read for a screen.
    private(set) var held: String?
    /// What Tailscale said about the credential this Mac holds, when it was last asked; nil while it has not been
    /// asked, or when Tailscale could not be reached, because neither is a reason to doubt the credential.
    private(set) var confirmed: NetworkStanding?
    /// What the credential is being used for or what it just did, in one line, in the owner's words.
    private(set) var said: String?
    private(set) var failure: String?
    private(set) var busy = false
    /// The credential as it is being pasted. Memory only, and emptied the moment it is kept.
    var draft = NetworkCredential()

    var isHeld: Bool { held != nil }

    /// Reads this Mac, and asks Tailscale whether the credential this Mac holds still works — so a credential
    /// that was revoked in Tailscale is seen here, and not at the next install.
    func read() async {
        let credential = NetworkCredentialStore.read()
        held = credential?.shownID
        mac = await MacNetwork.read()
        guard let credential else { confirmed = nil; return }
        confirmed = try? await NetworkClient().standing(credential)
    }

    /// Puts the tag back when it has gone from the owner's policy file. Nothing else can take it away.
    func makeReady() async {
        guard !busy, let credential = NetworkCredentialStore.read() else { return }
        busy = true; failure = nil; said = nil
        defer { busy = false }
        do {
            _ = try await NetworkClient().prepare(credential)
            confirmed = NetworkStanding(accepted: true, tagReady: true)
            said = String(l10n: "Your network has the tag \(PrivateNetwork.tag) again.")
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Takes the credential: Tailscale has to accept it, the tag has to be in place, and only then is it kept.
    func connect() async {
        guard !busy else { return }
        guard draft.isValid else { failure = draft.problem; return }
        busy = true; failure = nil; said = nil
        defer { busy = false }
        let credential = draft
        do {
            let wrote = try await NetworkClient().prepare(credential)
            try NetworkCredentialStore.save(credential)
            draft = NetworkCredential()
            held = credential.shownID
            confirmed = NetworkStanding(accepted: true, tagReady: true)
            said = wrote ? String(l10n: "Your network is ready. Tailscale now has the tag \(PrivateNetwork.tag), and this Mac makes the key each server needs.")
                : String(l10n: "Your network is ready. This Mac makes the key each server needs.")
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Ends it on this Mac. Tailscale's own copy is ended in Tailscale, which the row beside this one opens.
    func forget() {
        failure = nil
        do {
            try NetworkCredentialStore.forget()
            held = nil
            confirmed = nil
            said = String(l10n: "This Mac no longer holds it. End it in Tailscale as well, so nothing can use it.")
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Gets Tailscale's own installer for this Mac and hands it to the macOS installer, where the person approves
    /// it themselves. This app installs nothing and asks for no password.
    func installOnThisMac() async {
        guard !busy else { return }
        busy = true; failure = nil; said = nil
        defer { busy = false }
        do {
            _ = try await MacNetwork.install()
            said = String(l10n: "Tailscale's installer is open. Install it, allow it in System Settings → Privacy & Security, then sign in with your Tailscale account.")
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        await read()
    }

    func openTailscaleApp() async {
        await MacNetwork.openTailscale()
        await read()
    }

    func open(_ page: URL) { NSWorkspace.shared.open(page) }
}

/// The rows of the private network, which every screen that needs them shows the same way.
struct PrivateNetworkSection: View {
    @Bindable var model: PrivateNetworkModel
    /// Shown while a fleet is being set up: then this Mac matters as much as the machines.
    var showsThisMac = true
    /// The credential for the fleet's servers. **The first run's network step has none** (D-3, the owner's yes of 28
    /// October 2026): it asks for this Mac only, and the credential is asked for on the server install that needs it.
    var showsServers = true
    /// This Mac as a screen before this one read it (the first run's first page): the row draws it in its first frame
    /// and the section's own read replaces it. "Reading this Mac" stood 131 ms at every open of the network step.
    var known: MacNetwork.Standing? = nil
    /// The setup step's one size, where the section stands on one (item 45, fix round 2).
    @Environment(\.stepText) private var stepText

    var body: some View {
        VStack(alignment: .leading, spacing: FleetSpace.block) {
            if showsThisMac { thisMac }
            if showsServers { credential }
            if let said = model.said {
                Text(said).font(FormMetrics.onStep(stepText) ?? FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = model.failure {
                Text(failure).font(FormMetrics.onStep(stepText) ?? FormMetrics.detail).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("network-failure")
            }
        }
        .task { await model.read() }
    }

    // MARK: - This Mac

    /// One row: is this Mac on the private network? The mark answers, and the state's few words stand under the
    /// title. The four sentences this row used to carry a different one of — installed, signed in, connected, and the
    /// address it has — are behind the mark, and so is the one thing to press.
    @ViewBuilder private var thisMac: some View {
        FormSection("This Mac", footer: footer) {
            if let mac = model.mac ?? known {
                // **Each state its own words in the row** (fix round 2, item 100): "Not signed in" and "Not connected"
                // were one cross, and only the mark's hover told them apart. The mark and what is behind it stay.
                FormRow("Tailscale", symbol: "network", detail: mac.mark.words) {
                    StateMark(state: mac.mark.state, words: mac.mark.words, detail: detail(of: mac), act: act(of: mac.step))
                }
                .accessibilityIdentifier("network-mac")
            } else {
                FormMarkRow(title: "Tailscale", state: .working, symbol: "network", words: String(l10n: "Reading this Mac"),
                            identifier: "network-mac")
            }
        }
    }

    /// The one thing he presses, when this Mac is not on the network: Tailscale's own installer, or Tailscale
    /// itself, because signing in is his own step at his own provider.
    private func act(of step: MacNetwork.Standing.Step) -> (words: String, run: () -> Void)? {
        switch step {
        case .connected: nil
        case .notInstalled: (String(l10n: "Install Tailscale"), { Task { await model.installOnThisMac() } })
        case .notSignedIn, .notConnected: (String(l10n: "Open Tailscale"), { Task { await model.openTailscaleApp() } })
        }
    }

    /// What this Mac is, in Tailscale's own words, so no screen invents one.
    private func detail(of mac: MacNetwork.Standing?) -> String? {
        guard let mac else { return nil }
        if mac.step == .connected {
            let here = [mac.tailnet, mac.address].compactMap { $0 }.joined(separator: " · ")
            return here.isEmpty ? String(l10n: "This Mac is on your private network.") : here
        }
        if mac.step == .notInstalled { return String(l10n: "Your fleet is reachable only over it.") }
        return String(l10n: "Tailscale says: \(mac.says ?? String(l10n: "nothing yet")). Sign in there with your own account.")
    }

    private var footer: String? {
        (model.mac ?? known)?.step == .notInstalled
            ? String(l10n: "Tailscale's own installer, signed and checked before it opens. macOS asks for your password and for its system extension and VPN; this app asks for nothing.")
            : nil
    }

    // MARK: - The credential

    @ViewBuilder private var credential: some View {
        if model.isHeld { holding } else { asking }
    }

    private var asking: some View {
        // No paragraph under the card and no recipe under the row (D-2): the recipe is Open Tailscale's hover, where
        // he reads it as he goes there.
        FormSection("Your servers") {
            FormRow("Make a credential", symbol: "key") {
                Button("Open Tailscale") { model.open(PrivateNetwork.console) }
                    .buttonStyle(FleetOutlineButtonStyle())
                    .help("In Tailscale: Credential → OAuth, All to Write, Generate. The secret shows once.")
                    .accessibilityIdentifier("network-open-console")
            }
            FormRow("Client id", symbol: "number",
                    warning: model.draft.clientID.isEmpty ? nil : model.draft.clientIDProblem) {
                TextField(text: $model.draft.clientID, prompt: Text(verbatim: "")) { Text("kSomething") }
                    .fieldPlaceholder("kSomething", shows: model.draft.clientID.isEmpty)
                    .fleetField().frame(width: 240)
                    .accessibilityIdentifier("network-client-id")
            }
            FormRow("Client secret", symbol: "lock.shield") {
                SecureField(text: $model.draft.secret, prompt: Text(verbatim: "")) { Text("tskey-client-…") }
                    .fieldPlaceholder("tskey-client-…", shows: model.draft.secret.isEmpty)
                    .fleetField().frame(width: 240)
                    .accessibilityIdentifier("network-client-secret")
            }
            // Once the two fields hold a credential, and while it connects with its own word: never a grey button
            // (the owner: "dont show the send button if it's not clickable"). A press while it connects does nothing.
            if model.draft.isValid || model.busy {
                HStack {
                    Spacer()
                    Button(model.busy ? "Connecting…" : "Connect your network") { Task { await model.connect() } }
                        .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("network-connect")
                }
                .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 11)
            }
        }
    }

    /// The held credential as Tailscale answered for it, and no further than that: a Tailscale this Mac could not
    /// reach says nothing about the credential, so the mark does not either. The three sentences this row used to
    /// pick one of are the detail behind it.
    private var heldDetail: String {
        let mine = String(l10n: "Credential \(model.held ?? ""), in this Mac's keychain.")
        guard let confirmed = model.confirmed else { return mine }
        if !confirmed.accepted { return String(l10n: "It was ended in Tailscale, or it expired. \(mine)") }
        if !confirmed.tagReady {
            return String(l10n: "\(PrivateNetwork.tag) is no longer in your policy file, so no server can join until it is back. \(mine)")
        }
        return mine
    }

    /// A cross is never a dead end: a credential Tailscale no longer accepts is replaced where it was made, and a
    /// tag that is gone this app puts back itself.
    private var heldAct: (words: String, run: () -> Void)? {
        guard let confirmed = model.confirmed else { return nil }
        if !confirmed.accepted { return (String(l10n: "Open Tailscale"), { model.open(PrivateNetwork.console) }) }
        return confirmed.tagReady ? nil : (String(l10n: "Put the tag back"), { Task { await model.makeReady() } })
    }

    private var holding: some View {
        let mark = NetworkStanding.mark(model.confirmed)
        return FormSection("Your servers", footer: String(l10n: "Each server gets its own key, used once and worthless in fifteen minutes. Your servers are tagged \(PrivateNetwork.tag) in Tailscale, so they never sign in again.")) {
            FormMarkRow(title: String(l10n: "Your credential"), state: mark.state, symbol: "key", words: mark.words,
                        detail: heldDetail, act: heldAct, identifier: "network-held")
            FormRow("End it", symbol: "xmark.circle",
                    detail: String(l10n: "This Mac forgets it, and you delete it in Tailscale so nothing can use it again.")) {
                HStack(spacing: FleetSpace.actions) {
                    Button("Open Tailscale") { model.open(PrivateNetwork.revokePage) }
                        .buttonStyle(FleetOutlineButtonStyle())
                    Button("Forget") { model.forget() }.buttonStyle(FleetDangerButtonStyle())
                        .accessibilityIdentifier("network-forget")
                }.fixedSize()
            }
        }
    }
}

/// The other way a machine gets onto the private network: a block the owner pastes into the agent he already
/// runs, which puts one Linux machine on it. Nothing in it is secret — the key travels as the path of a file of
/// his own.
///
/// It stood on the Settings page until 20 October 2026, where it was a standing paragraph about Tailscale. It
/// belongs with the one question it answers, which an install asks when a machine cannot sign in by Tailscale's own
/// link: this machine is not on your network, so either this Mac mints its key from a credential, or your own agent
/// puts it there.
struct NetworkPromptSection: View {
    @State private var copied = false

    var body: some View {
        FormSection("Or let your own agent do it", footer: NetworkPrompt.says) {
            FormBlock("The prompt", detail: String(l10n: "It puts one Linux server on this network. It installs no Founderizer and signs nothing in.")) {
                ScrollView {
                    Text(NetworkPrompt.text).font(FormMetrics.code)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(height: 200)
                .background(FleetStyle.canvas, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
                .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner).strokeBorder(FleetStyle.line, lineWidth: 0.5))
                .accessibilityIdentifier("network-prompt")
            } accessory: {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(NetworkPrompt.text, forType: .string)
                    copied = true
                }.buttonStyle(FleetOutlineButtonStyle()).accessibilityIdentifier("network-prompt-copy")
            }
        }
    }
}
