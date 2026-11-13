import AppKit
import FleetCore
import FleetMark
import Observation
import SwiftUI

/// The first thing a customer sees: setting up their fleet, one decision at a time (PRODUCT.md 2).
///
/// Everything here is in their words, and they are never asked for a repository. **The first page is the fleet's
/// VPS** (the owner's yes of 10 November 2026 to the page with its five cards and nothing else): a provider that makes
/// it from one token, or any VPS by its address, and this Mac installs it over its own SSH connection.
///
/// **The agent that a customer already runs has no page here** (the same yes; of its card he asked "what does MY
/// Agent mean?!"). Its install prompt is on the website, that agent claims the hub from this Mac, and the first page
/// finds such a fleet by itself, again and again while it shows (`findFleet`).
@MainActor @Observable
final class FirstRunModel {
    enum Step: Equatable {
        /// Tailscale on this Mac: the install ends in a claim to an address on the owner's own private network, so a
        /// Mac that is not on it cannot finish. Skipped when it already is.
        case network
        /// The machine, for an install from this Mac.
        case machine
        /// The install, step by step, and then its checks.
        case installing
        /// The hub answers and this Mac is its owner.
        case done
        /// A copy of a fleet, put back onto this hub. It is offered on `done`, because the day he needs it he is
        /// standing in front of a fresh hub and not hunting through Settings (`RestoreView.swift`).
        case restore
        /// The address of a hub that already runs.
        case address
        /// The fleet's own Tailscale key, from one pasted access token: once, after this Mac is on the network.
        case key
        /// A VPS for the fleet: at Hetzner, at DigitalOcean, or any other by its address.
        case cloud
        /// The token of the provider that makes the fleet's VPS, then the build.
        case token(CloudProvider)
        /// Any VPS by its address: the check, its one-time password, and Install.
        case vps
    }

    /// From here on the wizard keeps the window. The hub answers in the middle of the wizard — at the claim of an
    /// install — and what this Mac proved comes after it, so a window that went to the app the moment a hub answered
    /// would sweep away its own last screen.
    var holdsWindow: Bool {
        switch step {
        case .network, .machine, .key, .cloud, .token, .vps: false
        case .installing, .address, .done, .restore: true
        }
    }

    /// The screen this wizard opens on. It is the first screen, the fleet's VPS, unless somebody asked for another one
    /// with `-firstRunStep <network|key|vps|machine|done|restore|address>`, which is how a screen of this wizard can be
    /// looked at without walking to it. The argument domain is not written to the app's settings, so it leaves no trace.
    var step: Step = FirstRunModel.asked ?? .cloud

    static var asked: Step? {
        switch UserDefaults.standard.string(forKey: "firstRunStep") {
        case "network": return .network
        case "machine": return .machine
        case "done": return .done
        case "restore": return .restore
        case "address": return .address
        case "key": return .key
        case "cloud": return .cloud
        case "vps": return .vps
        default: return nil
        }
    }
    /// Whether this Mac is on the owner's private network, read while the first screen shows; nil until then.
    private(set) var macReady: Bool?
    /// This Mac's private network as the first screen read it, for the network step's first frame.
    private(set) var mac: MacNetwork.Standing?
    /// The card the owner pressed, while the network screen or the key's stands in front of its page.
    private(set) var after: Step?
    var addressText = ""
    private(set) var busy = false
    private(set) var failure: String?
    /// What this Mac has proved about the fleet, as it proves it.
    private(set) var reached = false
    private(set) var owned = false
    /// An install of this wizard began: from then on the first page looks for no fleet by itself, so a Back from an
    /// install that stopped never connects to the hub that it left half made.
    private(set) var began = false

    /// How long the first page waits between two looks for a fleet (`findFleet`).
    static let looksEvery = Duration.seconds(5)

    /// Reads this Mac, so a press on a card can go straight on when there is nothing to say.
    func readMac() async {
        let standing = await MacNetwork.read()
        mac = standing
        macReady = standing.isConnected
    }

    /// The card the owner pressed. A Mac that is not on the private network is put on it first, and the fleet's own
    /// Tailscale key is made once before the first server: those are the only times their two screens are seen.
    func choose(_ way: Step) {
        if macReady == false {
            after = way
            start(.network)
        } else if !TailscaleFleetKey().isHeld {
            after = way
            start(.key)
        } else {
            start(way)
        }
    }

    /// On from the network screen, to the page of the card that was pressed before it, with the key's page first
    /// while this Mac holds no key.
    func onwards() {
        guard let next = after else { return start(.cloud) }
        start(TailscaleFleetKey().isHeld ? next : .key)
    }

    /// On from the key's screen, to the page of the card that was pressed before it.
    func afterKey() { start(after ?? .cloud) }

    /// **A fleet that already runs on this Mac's network is found by itself** ("I already have one" went with the
    /// onboarding of 4 November 2026): each device is asked for the hub, and only a fleet that serves this Mac is
    /// taken. **The first page asks again while it shows** (`looksEvery`), so a fleet that the owner's own agent
    /// installs meanwhile connects with nothing pasted: that agent claims the hub from this Mac. Nothing changes while
    /// the owner has gone on from the first page, or after an install of this wizard began.
    func findFleet(store: FleetStore) async {
        guard macReady == true, step == .cloud, !began, !busy, let hub = await FleetOnTailscale.findHub(),
              (try? await HubClient().stateReading(at: hub)) != nil, step == .cloud, !began, !busy else { return }
        await connect(to: hub.absoluteString, store: store, again: false)
    }

    /// A hub that answers and does not serve this Mac: it is somebody else's, or not claimed yet.
    static let notOwned = String(l10n: "Your hub answered, and it does not serve its pages to this Mac.")

    /// Connects, and says what this Mac has proved: the hub answers, and it serves its pages to this Mac, which is
    /// what being its owner means.
    ///
    /// **A hub that refused at once is read again by itself**, three times more, two seconds apart, and only then does
    /// the step say so, in HubReach's words without the address he just pasted (T-18). **One that timed out is not read
    /// again** (review A4, `HubReach.worthAgain`): it already waited. `again` false reads once.
    func connect(to address: String, store: FleetStore, again: Bool = true) async {
        // **Each try starts with no failure** (fix round 3, item 50): a second Connect that failed kept the first one's words.
        busy = true; failure = nil
        defer { busy = false }
        store.addressText = address
        var left = again ? HubReach.triesAgain : 0
        while true {
            await store.connect()
            reached = store.state != nil || store.connectionError?.contains("does not serve its pages") == true
            owned = store.state != nil
            // It answered, this Mac's or not: another read says the same.
            if reached { break }
            guard left > 0, let error = store.lastReadError, HubReach.worthAgain(error) else { break }
            left -= 1
            do { try await Task.sleep(for: HubReach.pause) } catch { break }
        }
        if owned {
            step = .done
        } else {
            failure = reached ? Self.notOwned : Self.words(store)
        }
    }

    /// **Why the read failed** (fix round 3, item 50): HubReach's line with no address, which is the one he just gave,
    /// and never the hub's own words — a refusal's second line is the hub's answer as it came ("(owner only)",
    /// "database is locked"), so a refusal says what failed and no more.
    static func words(_ store: FleetStore) -> String? {
        guard let error = store.lastReadError else {
            return store.connectionError.map { HubReach.withoutAddress($0, hub: store.hub) }
        }
        let reach = HubReach.words(error, hub: nil)
        if case .refusal(let status, _)? = error as? HubError, status != 404 { return reach.says }
        return reach.line
    }

    /// **A failure ends by itself when the app's own read reaches the hub** (fix round 3, item 50): the store reads its
    /// address every three seconds, and the step kept "Your hub did not answer." over a hub that had answered, until he
    /// pressed Return. The same address runs again, as Return runs it.
    func readsNow(store: FleetStore) async {
        guard failure != nil, !busy, store.state != nil, step == .address else { return }
        await connect(to: ClaimCode.hubAddress(in: addressText) ?? addressText, store: store)
    }

    func start(_ step: Step) {
        self.step = step
        failure = nil
        if step == .installing { began = true }
    }
}

/// The wizard. One screen, one decision, and a Back that goes one step.
///
/// **Each screen is a setup step, as an agent's setup is** (`SetupPage`, `SetupStep`; the owner, 28 October 2026, of
/// a wizard of the same app: "it has to be centered like the ai provider login"): the product's muted mark at the
/// size of every step's mark, the title under it, what the step asks under that, and Back at the page's top left,
/// which Esc follows too. The page puts the whole step in the middle of the window (`SetupPage`), and a wait is the
/// title's moving words and no spinner ("remove that circle, I liked the Thinking text animation").
struct FirstRunView: View {
    @Bindable var store: FleetStore
    @State private var model = FirstRunModel()
    /// This Mac's own private network.
    @State private var networkModel = PrivateNetworkModel()
    /// Putting a copy back, on the hub this wizard has just claimed.
    @State private var putBack = RestoreModel()
    /// This Mac on the private network, and the fleet's own Tailscale key.
    @State private var net = FleetNetworkModel()
    /// The fleet's VPS, made at a provider, or any VPS by its address.
    @State private var cloud = FleetCloudModel()
    @State private var vps = FleetVPSModel()
    /// True in the window itself, false for the copy that Settings shows before there is a hub: only the window
    /// is held open for the wizard's last screens.
    var window = false
    private var install: MachineInstallModel { store.installModel() }

    var body: some View {
        SetupPage { backLink } step: { screens }
        // The first page reads this Mac and looks for a fleet again and again while it shows (`FirstRunModel.findFleet`);
        // no other page of the wizard does.
        .task {
            while !Task.isCancelled {
                if model.step == .cloud {
                    await model.readMac()
                    await model.findFleet(store: store)
                }
                do { try await Task.sleep(for: FirstRunModel.looksEvery) } catch { return }
            }
        }
        .task { hold(model.holdsWindow) }
        .onChange(of: model.holdsWindow) { _, holds in hold(holds) }
    }

    /// The window belongs to the wizard until the owner leaves it.
    private func hold(_ holds: Bool) { if window { store.firstRunHolds = holds } }

    /// **Into the app, at the manager's chat**, and the wizard is done. Every way out of the wizard goes through here.
    /// The manager is the fleet's one agent and is not signed in yet, so its chat is its setup's two provider cards
    /// (`AgentSetupWizard`): the step that makes the first answer possible (D-3, the owner's yes of 28 October 2026;
    /// both providers since 4 November 2026).
    private func finish() {
        store.firstRunHolds = false
        store.destination = .agent(store.state?.agents.first { $0.role == "manager" }?.name ?? "manager")
    }

    /// The last press of an install. **No page of ours on the way** (D-3).
    private func openApp() { finish() }

    /// Whether this screen offers the second way on: begin a new fleet, or put a copy of one back.
    ///
    /// It is offered on the hub this Mac has just claimed, which is what `UI-API.md` 1.5 asks for and what the
    /// owner asked for on 20 October 2026 — on the day he needs it he is standing in front of a fresh hub, not
    /// hunting through Settings. A hub he only pointed the app at gets it too when it holds no work of its own,
    /// because that is the same fresh hub by another road; a working fleet does not, and has it on System status.
    private var offersRestore: Bool { RestoreOffer.atClaim(store.state, claimed: false) }

    /// The wizard sits in the middle of the window: there is little on each screen, on purpose, and little looks
    /// abandoned at the top of a large one.
    @ViewBuilder private var screens: some View {
        switch model.step {
        case .network: network
        case .machine, .installing: machine
        case .address: address
        case .done: done
        case .restore: restore
        case .key: key
        case .cloud: cloudStep
        case .token(let provider): token(provider)
        case .vps: vpsStep
        }
    }

    /// The mark over every step: the product's own, muted, at the size of every setup step's mark. It is background —
    /// no bar, no line, nothing boxed.
    private var mark: some View {
        FounderizerMark(size: SetupMetrics.mark, plate: Color.white.opacity(0.05), ink: Color.white.opacity(0.13))
            .accessibilityHidden(true)
    }

    /// One step back, at the top left of the page (`SetupPage`), where every setup page has it, and Esc too.
    /// **A build or an install that runs has no Back**, as Add server's has none: leaving it would leave a server half
    /// made at its provider, or take the password of a `sudo` that the running install still holds.
    private var runs: Bool {
        if case .token = model.step, cloud.stage == .making || cloud.stage == .joining { return true }
        return model.step == .installing && install.running
    }

    @ViewBuilder private var backLink: some View {
        if model.step != .cloud && !(model.step == .restore && putBack.running) && !runs {
            SetupBack { back() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("first-run-back")
        }
    }

    /// What a step asks, under its title: the rows and fields of before, read from their own leading edge as in a form.
    private func form(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 22) { content() }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func back() {
        switch model.step {
        case .machine, .address, .network, .key: model.start(.cloud)
        case .token: cloud.cancel(); model.start(.cloud)
        case .vps: vps.reset(); model.start(.cloud)
        // From a stopped install, to its form with what he typed (fix round 3, item 51): Back left the stop in place.
        case .installing: install.again(); vps.reset(); model.start(.cloud)
        case .restore: model.start(.done)
        case .done, .cloud: model.start(.cloud)
        }
    }

    // MARK: this Mac on the private network

    /// Tailscale on this Mac. One decision: put it in place. Only the Mac is asked about here — the credential
    /// that puts the fleet's own machines on the network is asked for where a machine is installed, and lives on
    /// the Settings page after that.
    private var network: some View {
        // **Connect Tailscale, and nothing else to read** (the onboarding of 4 November 2026): Connect brings Tailscale's
        // own installer, or Tailscale itself with its sign-in, whose first sign-in makes the owner's account and network.
        // The step reads this Mac every two seconds and goes on by itself once it is on the network.
        SetupStep(title: net.pressed ? String(l10n: "Waiting for Tailscale") : String(l10n: "Connect Tailscale"), waits: net.pressed) { NetworkMark() } content: {
            if !net.busy {
                if net.pressed {
                    SetupLink(String(l10n: "Open Tailscale again")) { Task { await net.connect() } }
                } else {
                    Button("Connect") { Task { await net.connect() } }
                        .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("first-run-network-connect")
                }
            }
            if let failure = net.failure { SetupWarning(failure) }
        }
        .task {
            while !Task.isCancelled {
                await net.read()
                if net.mac?.isConnected == true { model.onwards(); opensChoice(); return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    /// **The fleet's own Tailscale key, from one paste, once** (his "Yes, one paste" of 4 November 2026): the Keys page
    /// of Tailscale makes an access token, and the app makes the fleet's lasting key from it and forgets the token. Every
    /// server then joins with no press, and none expires.
    private var key: some View {
        SetupStep(title: net.busy ? String(l10n: "Connecting your network") : String(l10n: "Your Tailscale key"), waits: net.busy) { NetworkMark() } content: {
            if !net.busy {
                // What he does at Tailscale comes before the paste, so its steps stand over the field.
                SetupSteps.tailscaleKey
                PasteField(placeholder: String(l10n: "Paste it here"), text: $net.keyText, accepts: { $0.hasPrefix("tskey-api-") }) {
                    Task { if await net.sendKey() { model.afterKey(); opensChoice() } }
                }
                .accessibilityIdentifier("first-run-tailscale-key")
            }
            if let lines = net.linesToAdd { PolicyLines(lines: lines, copied: net.copied) { net.copyLines() } }
            if let failure = net.failure { SetupWarning(failure) }
        }
    }

    // MARK: the fleet's VPS

    private var serverMark: some View { IconTile(symbol: "server.rack", size: SetupMetrics.mark).accessibilityHidden(true) }

    /// **A VPS for the fleet, the wizard's first page: a card for each provider and one for any other VPS** (the owner,
    /// 4 November 2026: "we need to support other vps providers"; his yes of 9 November 2026 to Vultr and Akamai, each
    /// with its real logo and one short line; and his yes of 10 November 2026 to this page as the first one, with its
    /// cards and nothing under them). The fleet's own small VPS runs no agent (his decision of 2 November), and the
    /// manager gets a server of its own on its own page. A copy of a fleet goes back on the new hub, where the wizard
    /// offers it after the install (`offersRestore`).
    private var cloudStep: some View {
        SetupStep(title: String(l10n: "A VPS for your fleet"), width: SetupMetrics.cardsWidth) { mark } content: {
            CloudCards(id: "first-run", choose: { model.choose(.token($0)); opensChoice() }) {
                vps.reset(); model.choose(.vps)
            }
        }
    }

    /// A provider whose token this Mac holds opens its choice at once, in the frame its page comes: after the press on
    /// its card, and also after the network's screen or the key's that stood before its page. Else its token step asks
    /// for the token first. Nothing is made before the owner presses Make the server (the owner, 5 November 2026).
    private func opensChoice() {
        if case .token(let provider) = model.step, cloud.stage == .token, cloud.holds(provider) {
            cloud.open(provider, use: .hub)
        }
    }

    /// **A server of the account, chosen in place of a new one**: the same check and the same Install press as Other
    /// VPS, at its public address.
    private func useExisting(_ server: CloudExisting) {
        guard let address = server.ipv4 else { return }
        cloud.cancel(); vps.reset()
        vps.addressText = address; vps.tailnet = model.mac?.tailnet
        model.start(.vps)
        vps.check(job: .hub)
    }

    private func startInstall(_ target: InstallTarget, sudo: PasswordOnce.Password? = nil) {
        install.use(target, sudo: sudo)
        install.installHub(store: store)
        model.start(.installing)
    }

    private func token(_ provider: CloudProvider) -> some View {
        let building = cloud.stage == .making || cloud.stage == .joining
        let choosing = cloud.stage == .choosing
        return SetupStep(title: building ? String(l10n: "Building your fleet") : choosing ? String(l10n: "Your hub's server at \(provider.name)")
                            : String(l10n: "Your \(provider.name) token"),
                         waits: building || (choosing && cloud.offer == nil)) {
            // The provider's own logo over its pages, as Add server has it (the owner, 10 November 2026).
            CloudMark(provider: provider, size: SetupMetrics.mark)
        } content: {
            if building {
                CloudBuilding(stage: cloud.stage, provider: cloud.provider, showsStatus: true)
            } else if choosing {
                CloudChoice(cloud: cloud, job: .hub, fleet: [], makeNew: { cloud.makeNew { startInstall($0) } },
                            use: useExisting)
            } else {
                SetupSteps.token(provider)
                PasteField(placeholder: String(l10n: "Paste it here"), text: $cloud.tokenText,
                           accepts: { $0.count >= 20 && !$0.contains(" ") }) {
                    cloud.sendToken(provider, use: .hub)
                }
                .accessibilityIdentifier("first-run-cloud-token")
            }
            if let failure = cloud.failure { SetupWarning(failure) }
        }
    }

    /// **Any VPS, by its address** (the owner, 4 November 2026: "maybe users will only have ssh access to that server..
    /// with nothing else installed"): one field, the check, the password once when the VPS asks for one, then one
    /// Install press with the line of what changes, or one orange line of why not.
    @ViewBuilder private var vpsStep: some View {
        switch vps.phase {
        case .address:
            SetupStep(title: String(l10n: "Your VPS")) { serverMark } content: {
                SetupField(placeholder: String(l10n: "Address"), text: $vps.addressText) { vps.tailnet = model.mac?.tailnet; vps.check(job: .hub) }
                    .accessibilityIdentifier("first-run-vps-address")
            }
        case .checking:
            SetupStep(title: String(l10n: "Checking \(vps.host)"), waits: true) { serverMark }
        case .waiting(let why):
            SetupStep(title: String(l10n: "Waiting for \(vps.host)"), waits: true) { serverMark } content: {
                Text(why).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        case .password:
            SetupStep(title: String(l10n: "Password for \(vps.target?.user ?? "root")@\(vps.host)")) {
                IconTile(symbol: "lock", size: SetupMetrics.mark).accessibilityHidden(true)
            } content: {
                SetupSecureField(placeholder: String(l10n: "Password"), text: $vps.passwordText) { vps.givePassword(job: .hub) }
                    .accessibilityIdentifier("first-run-vps-password")
                Text("Used once, to add this Mac's key. Never kept.").foregroundStyle(FleetStyle.muted)
            }
        case .ready(let summary, let changes):
            SetupStep(title: vps.host) { serverMark } content: {
                Label { Text(summary) } icon: { Image(systemName: "checkmark").foregroundStyle(.green) }
                    .foregroundStyle(FleetStyle.text)
                Button("Install") { if let target = vps.target { startInstall(target, sudo: vps.sudoPassword) } }
                    .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("first-run-vps-install")
                Text(changes).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        case .stopped(let why):
            SetupStep(title: vps.host) { serverMark } content: {
                SetupWarning(why).accessibilityIdentifier("first-run-vps-stop")
                Button("Try again") { vps.again(job: .hub) }
                    .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: the install from this Mac

    @ViewBuilder private var machine: some View {
        if install.running || install.checklist != nil || install.failure != nil {
            // **While it runs, the moving title alone** (T-36's own change, fix round 2): "Installing your hub on
            // 203.0.113.9", and the step rows, the printed lines and the footer only after a failure. After its checks,
            // while this Mac connects to the hub it claimed, the title says that in moving words; then it is "Your
            // fleet is up", never "Installing your hub" again.
            let checked = !install.running && install.checklist != nil
            // **No "Your fleet is up" for a frame before the app** (fix round 3, item 49): when the app goes on by itself
            // (below), the moving title stands until it does. **A stop has a true title** (item 51): the title said
            // "Installing your hub on 203.0.113.9" over the stop.
            let connecting = checked && (store.state == nil || passed && !offersRestore)
            let stopped = !install.running && install.failure != nil
            let host = install.host.trimmingCharacters(in: .whitespacesAndNewlines)
            SetupStep(title: stopped ? String(l10n: "Your hub did not install") : connecting ? String(l10n: "Connecting to your hub")
                        : checked ? (passed ? String(l10n: "Your fleet is up") : String(l10n: "Your hub is installed"))
                        : String(l10n: "Building your fleet"),
                      waits: install.running || connecting) { mark } content: {
                form {
                    MachineInstallRun(model: install, title: String(l10n: "Your hub"), next: AnyView(afterInstall),
                                      again: { install.installHub(store: store) }, showsStatus: true)
                }
            }
            // **On to Manager's sign-in by itself** (D-3 item 1, his rule "it should just activate it"; fix round 2): when
            // the hub answers, its checks passed and no restore is offered, as the done step goes on. **A failed check
            // stops it** (review A6): its checks stand under "Your hub is installed", with Open Founderizer, as in 0.1.68.
            .onChange(of: checked && passed && store.state != nil && !offersRestore, initial: true) { _, onwards in
                if onwards { finish() }
            }
        } else {
            SetupStep(title: String(l10n: "Your server")) { mark } content: {
                form {
                    MachineInstallForm(model: install, taken: [], firstMachine: true) {
                        install.installHub(store: store)
                        model.start(.installing)
                    }
                }
            }
        }
    }

    /// The install's checks let the wizard go on: none failed, or only the sign-in, which is the step it goes on to.
    private var passed: Bool { install.checklist.map { $0.isReady || $0.onlyNeedsSignIn } ?? false }

    /// After an install that reached its checks: the hub claimed itself from this Mac, so the app is connected.
    /// Until the hub's first reading, the step's title says "Connecting to your hub" in moving words. Then, as the done
    /// step: with a restore offered, its two buttons under the title "Your fleet is up"; after a failed check, Open
    /// Founderizer under the checks; else the wizard goes on by itself (`machine`).
    @ViewBuilder private var afterInstall: some View {
        if store.state != nil && (offersRestore || !passed) {
            VStack(spacing: FleetSpace.inside) {
                HStack(spacing: 10) {
                    if offersRestore {
                        Button("Restore copy") { model.start(.restore) }
                            .buttonStyle(FleetOutlineButtonStyle())
                            .accessibilityIdentifier("first-run-install-restore")
                    }
                    Button(offersRestore ? "New fleet" : "Open Founderizer") { openApp() }
                        .buttonStyle(FleetPrimaryButtonStyle()).accessibilityIdentifier("first-run-open")
                }
                Text("Your hub serves its pages to this Mac and to nothing else.")
                    .font(SetupMetrics.textFont).foregroundStyle(FleetStyle.muted)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity)
        }
    }

    // MARK: a hub that already runs

    /// While this Mac asks the address for its fleet, the title's words move — "Checking your fleet", as on the claim
    /// step — and nothing else waits. **What stopped it is one orange line under the form**, as every setup step says
    /// it (fix round 3, item 50): it was a muted footer.
    private var address: some View {
        SetupStep(title: model.busy ? String(l10n: "Checking your fleet") : String(l10n: "Your hub's address"), waits: model.busy) { mark } content: {
            form { addressBlock }
            if let failure = model.failure { SetupWarning(failure).accessibilityIdentifier("first-run-address-failure") }
            // Only while it can act: no grey button (the owner: "dont show the send button if it's not clickable").
            if !model.busy && !model.addressText.isEmpty {
                Button("Connect") { Task { await model.connect(to: ClaimCode.hubAddress(in: model.addressText) ?? model.addressText, store: store) } }
                    .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("first-run-connect")
            }
        }
        .onChange(of: store.state != nil) { _, reads in if reads { Task { await model.readsNow(store: store) } } }
    }

    private var addressBlock: some View {
        Group {
            FormSection {
                FormRow("Address", symbol: "network") {
                    TextField(text: $model.addressText, prompt: Text(verbatim: "")) { Text("http://100.84.1.2:8765") }
                        .fieldPlaceholder("http://100.84.1.2:8765", shows: model.addressText.isEmpty)
                        .font(SetupMetrics.monoFont).fleetField()
                        .frame(width: 280).accessibilityIdentifier("first-run-hub-address")
                        .onSubmit { Task { await model.connect(to: ClaimCode.hubAddress(in: model.addressText) ?? model.addressText, store: store) } }
                }
            }
        }
    }

    // MARK: what this Mac proved

    private var allProved: Bool { model.reached && model.owned && store.state != nil }

    /// While its checks run, "Checking your fleet" is the title's moving words; a check that did not pass is its row,
    /// with no spinner. **When the three have passed, the app goes on by itself** to the manager's sign-in (D-3, his rule
    /// "it should just activate it"): no Open Founderizer to press, and no sentence of what comes next. A restore offer
    /// keeps its two choices, because that is a real decision.
    private var done: some View {
        // **"Your fleet is up" only with the offer that stays under it** (fix round 3, item 49): on a hub with work it stood
        // for 1–2 frames before the app; the moving words stand until the app takes the window.
        let stays = allProved && offersRestore
        return SetupStep(title: stays ? String(l10n: "Your fleet is up") : String(l10n: "Checking your fleet"), waits: !stays) { mark } content: {
            form { proofs }
            if allProved && offersRestore {
                HStack(spacing: 10) {
                    Button("Restore copy") { model.start(.restore) }
                        .buttonStyle(FleetOutlineButtonStyle())
                        .accessibilityIdentifier("first-run-restore")
                    Button("New fleet") { openApp() }
                        .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("first-run-done")
                }
            }
        }
        .onChange(of: allProved && !offersRestore, initial: true) { _, onwards in if onwards { finish() } }
    }

    /// **A check shows only while it has not passed** (D-2): three "Yes" rows that said the hub answers, that this Mac
    /// owns it and that the fleet reads stood on every first run; a check that did not pass keeps its row.
    private var proofs: some View {
        Group {
            FormSection(footer: allProved && offersRestore
                // Fifteen words at most (fix round 3, item 36): it was 25.
                ? String(l10n: "If this hub replaces one you lost, put your copy back first.") : nil) {
                if !model.reached { proof(String(l10n: "Your hub answers"), false, String(l10n: "This Mac reached it on your private network.")) }
                if !model.owned { proof(String(l10n: "This Mac is its owner"), false, String(l10n: "Your hub serves its pages to this Mac and to nothing else.")) }
                if store.state == nil { proof(String(l10n: "Your fleet is reading"), false, String(l10n: "Waiting for the first read.")) }
            }
        }
    }

    // MARK: putting a copy back

    /// The copy, on the hub this wizard has just claimed. Everything it does is `RestoreRows`, which System
    /// status shows as well, so there is one restore in this app and not two.
    private var restore: some View {
        SetupStep(title: String(l10n: "Restore a copy")) { mark } content: {
            form {
                // One sentence about the hub keeping its address, the restore's own (D-2): this one said it twice.
                FormSection {
                    RestoreRows(store: store, model: putBack,
                                go: { store.firstRunHolds = false; store.destination = $0 },
                                whenDone: { openApp() })
                }
            }
        }
    }

    /// One check of the done step: "Yes" once it passed, and no spinner while it runs — the title's words move.
    private func proof(_ title: String, _ yes: Bool, _ detail: String) -> some View {
        FormRow(title, symbol: yes ? "checkmark.circle.fill" : "circle.dashed", detail: detail) {
            if yes { Text("Yes").font(SetupMetrics.textFont).foregroundStyle(.green) }
        }
    }
}
