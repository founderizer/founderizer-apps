import AppKit
import FleetCore
import FleetMark
import Observation
import SwiftUI

// The steps of a fleet's setup that the owner approved on 4 November 2026 ("Yes, build it", the page "Founderizer
// Onboarding", version 7): Connect Tailscale and its key, a VPS for the fleet at Hetzner, at DigitalOcean (and, since
// 9 November 2026, at Vultr or Akamai) or at any provider, and the check of a VPS with its one-time password. Each is a centered setup step (`SetupStep`).

/// **A field that a key or a token is pasted into, which sends it by itself** (`CodeField`'s rule, "Paste and it
/// sends"): a paste that `accepts` takes goes at once, and so does Return. A paste that it does not take shows in the
/// field's own border. **Its words are the step's own, never monospaced** (the owner, 10 November 2026: "when pasting
/// a key, I dont want to show the typical 'console' font"), as a two-factor code screen shows its code in its product's
/// own typeface.
struct PasteField: View {
    let placeholder: String
    @Binding var text: String
    let accepts: (String) -> Bool
    let send: () -> Void
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var wrong: Bool { !trimmed.isEmpty && !accepts(trimmed) }

    var body: some View {
        TextField(text: $text, prompt: Text(verbatim: "")) { Text(placeholder) }
            .fieldPlaceholder(placeholder, shows: text.isEmpty)
            .setupField(focus: $focused, wrong: wrong)
            .onSubmit { if accepts(trimmed) { send() } }
            .onChange(of: text) { before, after in
                if after.count - before.count >= 8, accepts(after.trimmingCharacters(in: .whitespacesAndNewlines)) { send() }
            }
            .task { focused = true }
    }
}

/// **The steps over a key's field, in each provider's own words** (`SetupSteps`): the page to open, the press that makes
/// the key with the access the app needs, and its copy. Checked against each provider's own help on 10 November 2026.
extension SetupSteps {
    /// Tailscale's Keys page makes the access token from which the app makes the fleet's own key.
    static var tailscaleKey: SetupSteps {
        SetupSteps(["Open [Keys](\(TailscaleFleetKey.keysPage.absoluteString)) in Tailscale",
                    "Generate access token, then copy it"])
    }

    /// An AI provider's sign-in that gives a code to paste back (Claude Code's): its page, which the link opens (and
    /// which opened by itself after his press on the provider's card), and the code it shows after the sign-in.
    static func signIn(at page: URL, width: CGFloat? = SetupMetrics.field) -> SetupSteps {
        SetupSteps(["Open [the sign-in page](\(page.absoluteString))", "Sign in, then copy the code it shows"], width: width)
    }

    /// An AI provider's sign-in that shows a code to enter on its page (Codex's device code): its page, which the link
    /// opens and copies the code for, and the code under the steps. The page goes on by itself once he signed in.
    static func deviceCode(at page: URL, width: CGFloat? = SetupMetrics.field) -> SetupSteps {
        SetupSteps(["Open [the sign-in page](\(page.absoluteString))", "Sign in, then enter this code"], width: width)
    }

    /// A VPS provider's token: Read & Write at Hetzner, Full Access at DigitalOcean, the account's API key at Vultr
    /// (which takes calls from any address until its owner limits them), and Linodes and Firewalls at Akamai.
    static func token(_ provider: CloudProvider) -> SetupSteps {
        let page = FleetCloudModel.tokenPage(provider).absoluteString
        switch provider {
        case .hetzner:
            return SetupSteps(["Open your project in [Hetzner Console](\(page))", "Security › API tokens › Generate API token",
                               "Choose Read & Write, then copy the token"])
        case .digitalOcean:
            return SetupSteps(["Open [API](\(page)) in DigitalOcean", "Generate New Token with Full Access", "Copy the token"])
        case .vultr:
            return SetupSteps(["Open [API](\(page)) in Vultr", "Enable API, then copy the key"])
        case .akamai:
            return SetupSteps(["Open [API Tokens](\(page)) in Akamai", "Create a Personal Access Token",
                               "Set Linodes and Firewalls to Read/Write", "Create Token, then copy it"])
        }
    }
}

/// **The mark of the private network's steps: Tailscale's real logo on its tile**, as a VPS provider's own page has its
/// logo (`CloudMark`; the owner, 10 November 2026: "still no logos?"). Nine dots in Tailscale's ink: the four of its T
/// full, the other five faint, as Tailscale draws it.
struct NetworkMark: View {
    var size: CGFloat = SetupMetrics.mark

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: size * 0.26)
        // In Tailscale's own 24-point drawing, each dot is 6 across and the dots are 9 apart.
        let logo = size * 0.65, dot = logo / 4, step = logo * 3 / 8
        ZStack {
            tile.fill(Color.white)
            ForEach(0..<9, id: \.self) { index in
                Circle().fill(Self.ink.opacity(Self.full.contains(index) ? 1 : 0.2))
                    .frame(width: dot, height: dot)
                    .offset(x: CGFloat(index % 3 - 1) * step, y: CGFloat(index / 3 - 1) * step)
            }
        }
        .frame(width: size, height: size)
        .clipShape(tile)
        .accessibilityHidden(true)
    }

    /// The dots of the T, by row from the top: the whole middle row and the middle dot under it.
    static let full: Set<Int> = [3, 4, 5, 7]
    /// Tailscale's ink, #242424.
    static let ink = Color(red: 36 / 255, green: 36 / 255, blue: 36 / 255)
}

// MARK: - Tailscale on this Mac, and the fleet's own key

@MainActor @Observable
final class FleetNetworkModel {
    private(set) var mac: MacNetwork.Standing?
    private(set) var busy = false
    private(set) var failure: String?
    /// The access token as it is pasted: memory only, and emptied the moment it is sent.
    var keyText = ""
    /// The lines that the owner adds to a policy file that another tool keeps; nil while none are needed.
    private(set) var linesToAdd: String?
    private(set) var copied = false
    /// Connect was pressed: the step waits for Tailscale, and its title moves.
    private(set) var pressed = false

    /// Whether this Mac holds the fleet's own Tailscale key, from which every server's join key is made.
    var holdsKey: Bool { TailscaleFleetKey().isHeld }

    func read() async { mac = await MacNetwork.read() }

    /// Connect: Tailscale's own installer when this Mac has none, else Tailscale itself, which shows its sign-in. The
    /// step then reads this Mac every two seconds and goes on by itself once it is on the network.
    func connect() async {
        guard !busy else { return }
        busy = true; failure = nil; pressed = true
        defer { busy = false }
        if mac?.step == .notInstalled {
            do { _ = try await MacNetwork.install() } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        } else {
            _ = await MacNetwork.openTailscale()
        }
        await read()
    }

    /// The pasted access token makes the fleet's own key, and goes. `true` once the key is held.
    func sendKey() async -> Bool {
        let token = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        keyText = ""
        guard !busy, !token.isEmpty else { return false }
        busy = true; failure = nil; linesToAdd = nil; copied = false
        defer { busy = false }
        do {
            let setup = try await TailscaleFleetKey().connect(accessToken: token)
            linesToAdd = setup.linesToAdd
            return setup.keyMade && setup.linesToAdd == nil
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func copyLines() {
        guard let linesToAdd else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(linesToAdd, forType: .string)
        copied = true
    }
}

// MARK: - A VPS made at a provider

@MainActor @Observable
final class FleetCloudModel {
    /// `choosing`: the provider's own servers and the new one, of which the owner chooses one before anything is made
    /// (the owner's yes of 5 November 2026: "we need to ASK the user before these actions to confirm").
    enum Stage: Equatable { case token, choosing, making, joining }
    private(set) var stage: Stage = .token
    private(set) var failure: String?
    /// The provider of the server being made, or of the last try: a page left while it is made opens on it again.
    private(set) var provider: CloudProvider?
    /// The token as it is pasted: memory only, and emptied the moment it is sent.
    var tokenText = ""
    /// While the owner chooses: the server this app would make, and the servers the account holds already. nil while
    /// they are read.
    private(set) var offer: CloudOffer?
    private(set) var existing: [CloudExisting] = []
    /// The chosen server of the account, by its id; nil for the new one.
    var chosen: String?
    /// What the server is for, from the press that opened the choice.
    private(set) var use: CloudServerUse = .hub
    /// "Servers in another project?": the next token replaces the one this Mac holds for Hetzner.
    private(set) var anotherProject = false
    private var work: Task<Void, Never>?

    /// How long a new server has to join the private network after it was made, and how often it is looked for.
    static let joinWithin = 300.0, lookEvery = 5.0

    /// Where each provider makes the token, for the step's one link.
    static func tokenPage(_ provider: CloudProvider) -> URL {
        switch provider {
        case .hetzner: URL(string: "https://console.hetzner.cloud/projects")!
        case .digitalOcean: URL(string: "https://cloud.digitalocean.com/account/api/tokens")!
        case .vultr: URL(string: "https://my.vultr.com/settings/#settingsapi")!
        case .akamai: URL(string: "https://cloud.linode.com/profile/tokens")!
        }
    }

    func holds(_ provider: CloudProvider) -> Bool { !anotherProject && CloudServers(provider: provider).isHeld }

    /// A token goes once, and once the provider took it the choice opens (`open`). The title moves from the press on:
    /// the field emptied and the page stood still while the token was checked.
    func sendToken(_ provider: CloudProvider, use: CloudServerUse) {
        let token = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        tokenText = ""
        guard work == nil, !token.isEmpty else { return }
        failure = nil; self.provider = provider; self.use = use; anotherProject = false
        offer = nil; existing = []; chosen = nil; stage = .choosing
        work = Task { [weak self] in
            guard let self else { return }
            defer { work = nil }
            do { try await CloudServers(provider: provider).connect(token: token) } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                stage = .token
                return
            }
            await read(provider, use: use)
        }
    }

    /// **Before anything is made: the servers of the account and the new one, with its price** (the owner's yes of 5
    /// November 2026). Nothing is made until the owner presses Make the server.
    func open(_ provider: CloudProvider, use: CloudServerUse) {
        guard work == nil else { return }
        failure = nil; self.provider = provider; self.use = use
        offer = nil; existing = []; chosen = nil; stage = .choosing
        work = Task { [weak self] in
            guard let self else { return }
            defer { work = nil }
            await read(provider, use: use)
        }
    }

    /// The new server's offer and the account's servers, read together. A list that cannot be read leaves the new
    /// server alone, which is the step as it was before the list.
    private func read(_ provider: CloudProvider, use: CloudServerUse) async {
        let servers = CloudServers(provider: provider)
        async let listed = try? servers.servers()
        do {
            offer = try await servers.offer(use: use)
            existing = await listed ?? []
        } catch {
            _ = await listed
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            stage = .token
        }
    }

    /// The account's server chosen in the list, or nil for the new one.
    var chosenServer: CloudExisting? { existing.first { $0.id == chosen } }

    /// **Make the server**: the new one, exactly as the step showed it, and nothing else (`createServer`'s `offer`).
    func makeNew(then install: @escaping (InstallTarget) -> Void) {
        guard work == nil, let provider, let offer, stage == .choosing else { return }
        failure = nil; stage = .making
        work = Task { [weak self] in
            guard let self else { return }
            defer { work = nil }
            await build(provider, use: use, offer: offer, then: install)
        }
    }

    /// "Servers in another project?": back to the token's field, for a token of that project, which then replaces the
    /// one this Mac holds (a Hetzner token sees its own project only).
    func askAnotherProject() {
        guard work == nil else { return }
        anotherProject = true; failure = nil; offer = nil; existing = []; chosen = nil; stage = .token
    }

    /// **The server, made with nothing typed**: a name no device of the network has, this Mac's own SSH key, a join key
    /// for that one server from the fleet's own Tailscale key, and the provider's firewall with no way in. Then the
    /// server joins the private network by itself, and the install goes on over it.
    private func build(_ provider: CloudProvider, use: CloudServerUse, offer: CloudOffer,
                       then install: @escaping (InstallTarget) -> Void) async {
        stage = .making
        do {
            let name = FleetOnTailscale.freeName(in: await MacNetwork.status() ?? "{}")
            let publicKey = try await AppSSHKey.make()
            let authKey = try await TailscaleFleetKey().mintAuthKey(hostname: name)
            _ = try await CloudServers(provider: provider).createServer(name: name, use: use, publicKey: publicKey,
                                                                         authKey: authKey, offer: offer)
            stage = .joining
            let until = Date().addingTimeInterval(Self.joinWithin)
            while Date() < until, !Task.isCancelled {
                if let status = await MacNetwork.status(),
                   let device = FleetOnTailscale.devices(in: status).first(where: { $0.name == name && $0.online }) {
                    install(InstallTarget(host: device.address, user: "root", port: 22, identityFile: AppSSHKey.path()))
                    stage = .token
                    return
                }
                try await Task.sleep(for: .seconds(Self.lookEvery))
            }
            failure = "\(name) did not join your network within five minutes. Open it in \(provider.name)'s console."
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        stage = .token
    }

    /// Ends a build or a choice, and forgets a paste that was never sent.
    func cancel() {
        work?.cancel(); work = nil; stage = .token; failure = nil; provider = nil; tokenText = ""
        offer = nil; existing = []; chosen = nil; anotherProject = false
    }
}

// MARK: - Any VPS, by its address

@MainActor @Observable
final class FleetVPSModel {
    enum Phase: Equatable {
        case address, checking
        case password(ServerCheck.PasswordNeed)
        case waiting(String)
        case ready(summary: String, changes: String)
        case stopped(String)
    }

    var addressText = ""
    /// The password as it is typed: memory only, emptied the moment it is sent (`PasswordOnce`).
    var passwordText = ""
    private(set) var phase: Phase = .address
    private(set) var target: InstallTarget?
    /// The password of a `sudo` that asks for one, for the install that follows, which clears it when it ends.
    private(set) var sudoPassword: PasswordOnce.Password?
    /// The name of this Mac's own network, for the stop of a server that is on another one.
    var tailnet: String?
    private var work: Task<Void, Never>?

    var host: String { target?.host ?? addressText.trimmingCharacters(in: .whitespacesAndNewlines) }

    func check(job: InstallJob) {
        let typed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, work == nil else { return }
        phase = .checking
        work = Task { [weak self] in
            guard let self else { return }
            defer { work = nil }
            let named = await InstallTarget.named(typed)
            target = named
            await read(named, job: job)
        }
    }

    /// One check, and a busy server read again every fifteen seconds until it says something else. The key file that
    /// let the check in is the server's key from then on: for the password's step and for the install (`ServerCheck.run`).
    private func read(_ target: InstallTarget, job: InstallJob) async {
        var target = target
        while !Task.isCancelled {
            let result = await ServerCheck.run(target, job: job, holdsSudoPassword: sudoPassword != nil, tailnet: tailnet)
            target = result.target
            self.target = target
            switch result.verdict {
            case .ready(let summary, let changes): phase = .ready(summary: summary, changes: changes); return
            case .needsPassword(let need): phase = .password(need); return
            case .stop(let why): phase = .stopped(why); return
            case .wait(let why):
                phase = .waiting(why)
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }

    func givePassword(job: InstallJob) {
        guard case .password(let need) = phase, let target, !passwordText.isEmpty, work == nil else { return }
        let password = PasswordOnce.Password(passwordText)
        passwordText = ""
        phase = .checking
        work = Task { [weak self] in
            guard let self else { return }
            defer { work = nil }
            switch await PasswordOnce.run(target, need: need, password: password) {
            case .ready(let keyed, let keeps):
                self.target = keyed
                sudoPassword = keeps ? password : nil
                await read(keyed, job: job)
            case .refused(let why):
                phase = .stopped(why)
            }
        }
    }

    func again(job: InstallJob) {
        guard let target, work == nil else { reset(); return }
        phase = .checking
        work = Task { [weak self] in
            guard let self else { return }
            defer { work = nil }
            await read(target, job: job)
        }
    }

    func reset() {
        work?.cancel(); work = nil
        phase = .address
        sudoPassword?.clear(); sudoPassword = nil
    }
}

// MARK: - The views of the steps

/// One choice of a step, as a card: a mark and a name of a few words, and nothing else (the owner, 3 November 2026:
/// "too much text").
/// **A choice of a setup step, as a card**: its mark, its name, and one short line under the name where it has one (the
/// owner's yes of 9 November 2026 to the VPS page: "each option with the proper logo and maybe a very short description
/// below"). The line is at the step's one size, muted.
struct SetupChoice<Mark: View>: View {
    let title: String
    var line: String?
    @ViewBuilder var mark: () -> Mark
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 10) {
                mark()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(SetupMetrics.choiceFont).foregroundStyle(FleetStyle.text)
                    if let line { Text(line).font(SetupMetrics.textFont).foregroundStyle(FleetStyle.muted) }
                }
                .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
            }
            .padding(18).frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(FleetCardButtonStyle())
    }
}

/// **The VPS page's cards, three in a row** (the owner's yes of 9 November 2026 to the page that showed them, "Yes, build
/// it"): each provider that makes the server from one token, with its real logo and one short line under its name, and
/// Other VPS, any server by its address, last. The first run's VPS for the fleet and Add server's VPS for the agents
/// show the same cards; `id` starts the accessibility name of each.
struct CloudCards: View {
    let id: String
    let choose: (CloudProvider) -> Void
    let other: () -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 3), spacing: 14) {
            ForEach(CloudProvider.allCases, id: \.self) { provider in
                SetupChoice(title: provider.name, line: Self.line(provider), mark: { CloudMark(provider: provider) },
                            choose: { choose(provider) })
                    .accessibilityIdentifier("\(id)-cloud-\(provider.rawValue)")
            }
            SetupChoice(title: "Other VPS", line: "Any server by SSH", mark: { IconTile(symbol: "server.rack") }, choose: other)
                .accessibilityIdentifier("\(id)-cloud-other")
        }
    }

    /// The short line under each provider's name, in the words the owner approved.
    static func line(_ provider: CloudProvider) -> String {
        switch provider {
        case .hetzner: "Best price"
        case .digitalOcean: "Simple to use"
        case .vultr: "Many regions"
        case .akamai: "Formerly Linode"
        }
    }
}

/// **A cloud provider's real logo on its tile** (`CloudLogo`), at the size of a card's mark, and at the step's mark over
/// the provider's own pages (its token, its choice and its build): a white tile with the provider's mark in its middle,
/// and Hetzner's red square as the whole tile.
struct CloudMark: View {
    let provider: CloudProvider
    var size: CGFloat = 34

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: size * 0.26)
        let logo = CloudLogo.fillsTile(provider.rawValue) ? size : size * 0.65
        ZStack {
            tile.fill(Color.white)
            CloudLogo.image(provider.rawValue)?.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: logo, height: logo)
        }
        .frame(width: size, height: size)
        .clipShape(tile)
        .accessibilityHidden(true)
    }
}

/// The lines a policy file that another tool keeps must get, with their one Copy.
struct PolicyLines: View {
    let lines: String
    let copied: Bool
    let copy: () -> Void

    var body: some View {
        VStack(spacing: SetupMetrics.gap) {
            SetupWarning("Another tool keeps your Tailscale policy. Add these lines there, then paste a key again.")
            ScrollView([.vertical, .horizontal]) {
                Text(lines).font(FormMetrics.code).textSelection(.enabled).fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .frame(height: 140)
            .background(FleetStyle.canvas, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
            .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner).strokeBorder(FleetStyle.line, lineWidth: 0.5))
            .multilineTextAlignment(.leading)
            Button(copied ? "Copied" : "Copy") { copy() }.buttonStyle(FleetPrimaryButtonStyle())
        }
    }
}

/// **The servers of the account and a new one, before anything is made** (the owner's yes of 5 November 2026 to the
/// list of existing servers, "they should be able to choose them instead of adding new ones", and to the step that
/// asks before a server is made, "they need to know!"). Each server of the account is a row, and the new server is the
/// last one, with what it costs; a server that cannot be used is grey with its short reason. An account with no
/// server shows the new server alone: its size, where, and what it costs. The one press says what it does. A Hetzner
/// token sees its own project only, so its list offers another project's token.
struct CloudChoice: View {
    @Bindable var cloud: FleetCloudModel
    let job: InstallJob
    /// The names of the fleet's own servers, in lower case.
    let fleet: Set<String>
    let makeNew: () -> Void
    let use: (CloudExisting) -> Void

    var body: some View {
        if let offer = cloud.offer {
            VStack(spacing: SetupMetrics.gap) {
                if cloud.existing.isEmpty { alone(offer) } else { list(offer) }
                Button(cloud.chosenServer == nil ? "Make the server" : "Use this server") {
                    if let server = cloud.chosenServer { use(server) } else { makeNew() }
                }
                .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("cloud-choice-press")
                if cloud.provider == .hetzner {
                    SetupLink("Servers in another project?") { cloud.askAnotherProject() }
                        .accessibilityIdentifier("cloud-choice-project")
                }
            }
        }
    }

    /// The new server alone: what it is, where, and what it costs.
    private func alone(_ offer: CloudOffer) -> some View {
        FormSection {
            FormRow("Size") { value(offer.size) }
            FormRow("Location") { value(offer.place) }
            FormRow("Price") { value("\(offer.monthly), billed by \(offer.provider.name)") }
        }
        .accessibilityIdentifier("cloud-choice-new")
    }

    private func value(_ words: String) -> some View {
        Text(words).font(SetupMetrics.textFont).foregroundStyle(FleetStyle.muted).lineLimit(1).minimumScaleFactor(0.8)
    }

    /// The account's servers, then the new one, chosen by default.
    private func list(_ offer: CloudOffer) -> some View {
        FormSection {
            ForEach(cloud.existing) { server in
                let why = server.unfit(for: job, fleet: fleet)
                row(server.name, detail: [server.summary, why].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                    chosen: cloud.chosen == server.id, usable: why == nil) { cloud.chosen = server.id }
            }
            row("New server", detail: offer.row, chosen: cloud.chosen == nil, usable: true) { cloud.chosen = nil }
        }
        .accessibilityIdentifier("cloud-choice-list")
    }

    private func row(_ title: String, detail: String, chosen: Bool, usable: Bool,
                     choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            FormRow(title, symbol: chosen ? "largecircle.fill.circle" : "circle", detail: detail) { EmptyView() }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!usable).opacity(usable ? 1 : 0.45)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// While a server is made at a provider and joins the private network: the moving title of the whole build, and
/// its first two steps.
struct CloudBuilding: View {
    let stage: FleetCloudModel.Stage
    /// The install that follows the build: the fleet's own VPS, or a server that joins it.
    var job: InstallJob = .hub
    /// The provider that makes the server, for the line of what runs now.
    var provider: CloudProvider?
    /// The line of what runs now under the title: the first run's "Building your fleet" only (the owner's yes of 5
    /// November 2026).
    var showsStatus = false

    var body: some View {
        SetupPhases(names: InstallPhases.names, current: stage == .joining ? 1 : 0, minutesLeft: minutesLeft,
                    status: showsStatus ? status : nil)
            .accessibilityIdentifier("cloud-phases")
    }

    private var status: String? {
        switch stage {
        case .making: provider.map { "Making your server at \($0.name)" } ?? "Making your server"
        case .joining: "Starting your server"
        case .token, .choosing: nil
        }
    }

    /// The build's own time while the server is made (about 75 seconds on the proof run of 5 November 2026, from the
    /// press to the server on the private network), and the steps of the install that follows, as its plan names them,
    /// rounded up as the install's page rounds them.
    private var minutesLeft: Int {
        let target = InstallTarget(host: "server")
        let plan = job == .hub ? InstallPlan.hub(target: target, source: "", authKey: nil)
            : InstallPlan.join(target: target, line: "", code: "", authKey: nil)
        let seconds = plan.steps.reduce(stage == .joining ? 0 : 75) {
            $0 + (InstallPhases.seconds[$1.id] ?? InstallPhases.otherStep)
        }
        return Int((Double(seconds) / 60).rounded(.up))
    }
}

/// **The one-time password's field**: the app's one field in the step's size, with its dots, its cursor when the step
/// opens, and Return to send it (`PasswordOnce`).
struct SetupSecureField: View {
    let placeholder: String
    @Binding var text: String
    let submit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        SecureField(text: $text, prompt: Text(verbatim: "")) { Text(placeholder) }
            .fieldPlaceholder(placeholder, shows: text.isEmpty)
            .setupField(focus: $focused)
            .onSubmit(submit)
            .task { focused = true }
    }
}
