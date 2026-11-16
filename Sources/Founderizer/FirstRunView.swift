import AppKit
import FleetCore
import FleetMark
import FleetOwnerAPI
import Observation
import SwiftUI

/// The first thing a customer sees: setting up their fleet, one decision at a time (PRODUCT.md 2).
///
/// Everything here is in their words, and they are never asked for a repository. **The first page is the welcome
/// page** (`WelcomePage`; the owner, 14 November 2026: "it has to be a specific page, the first page! the onboarding
/// needs to be MUCH nicer, think about this... users JUST installed founderizer! we need some nice visuals, effects,
/// etc... and the option to set it up manually OR copy a prompt and let Claude/Code do it for them", and "Yes, build
/// it" to its moving mock): the team, its title and two ways. "Set it up yourself" goes to
/// the fleet's VPS (the owner's yes of 10 November 2026 to that page with its five cards and nothing else): a provider
/// that makes it from one token, or any VPS by its address, and this Mac installs it over its own SSH connection. The
/// second way copies one prompt for the owner's own agent, Claude Code or Codex, and shows it to paste (`PastePage`).
///
/// **On 10 November 2026 the owner took an agent's card off the first page.** The second way of the welcome page is the way he asked for on 14 November 2026 in its place: one card
/// with the names of the programs that this Mac has, and no program's logo. That agent claims the hub from this Mac,
/// and the first pages find such a fleet by itself, again and again while they show (`findFleet`). When it runs
/// `founderizer-cli guide`, the app goes on to "Name your manager", the first page of the first way, and comes to
/// the front (`agentStartedGuide`).
///
/// **A fleet whose setup never finished opens on the welcome page too** (`FirstRunView.resumes`; the owner's yes of 14
/// November 2026): the same page and the page after its press, in front of the setup of a manager that has no server
/// yet. There the first way and the guide's sign go on to that setup (`WelcomeRules.firstWay`), no fleet is looked
/// for, and no other page of this wizard shows.
@MainActor @Observable
final class FirstRunModel {
    enum Step: Equatable {
        /// The welcome page: the team, its title and its two ways.
        case welcome
        /// The prompt for the owner's own agent, after the press on the welcome page's second way.
        case paste
        /// "Name your manager", the first page of the welcome page's first way (the owner, 15 November 2026: "but
        /// initially we should ask the manager name? I would focus the onboarding in creating the manager", and "Yes,
        /// build it" to its picture).
        case name
        /// "Your fleet's servers", the slider from the lower cost to the more secure, after the manager's name (his
        /// "where is the slider with price <> security we designed", and "Steps first", of 15 November 2026).
        case servers
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
        case .welcome, .paste, .name, .servers, .network, .machine, .key, .cloud, .token, .vps: false
        case .installing, .address, .done, .restore: true
        }
    }

    /// The screen this wizard opens on. It is the first screen, the welcome page, unless somebody asked for another one
    /// with `-firstRunStep <welcome|paste|name|servers|cloud|network|key|vps|machine|done|restore|address>`, which is how a screen of
    /// this wizard can be looked at without walking to it. It is read from the start's arguments only (`asked`), which
    /// are not written to the app's settings, so it leaves no trace.
    var step: Step = FirstRunModel.asked ?? .welcome

    /// The programs of the owner's own agent on this Mac (`AgentPrograms`): read once, the first time a page asks for
    /// them, and again each time the welcome page shows again (`start`). **Not in a stored value's first value**: SwiftUI
    /// makes a new `FirstRunModel` at each new value of `FirstRunView` and keeps only the first, so a read there ran
    /// about ten file checks on the main thread for each one.
    var programs: Set<AgentPrograms.Program> {
        if let found = foundPrograms { return found }
        let found = AgentPrograms.found()
        foundPrograms = found
        return found
    }
    @ObservationIgnored private var foundPrograms: Set<AgentPrograms.Program>?
    /// The prompt is on the clipboard: the page after the press says Copied.
    private(set) var promptCopied = false

    /// The page as the rules of the welcome page tell them apart (`WelcomeRules`).
    var page: WelcomeRules.Page {
        switch step {
        case .welcome: .welcome
        case .paste: .paste
        case .cloud: .cloud
        // The two pages of the first way before this Mac's network: both look for a fleet, neither is a start page,
        // and no new build of the app goes in by itself on either.
        case .name, .servers: .name
        default: .other
        }
    }

    /// **Only the start's own arguments** (`UserDefaults.argumentDomain`), never a kept setting: a `defaults write` of
    /// this name would open each start of the app on that page, for example on the VPS page with no name asked.
    static var asked: Step? {
        switch UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["firstRunStep"] as? String {
        case "welcome": return .welcome
        case "paste": return .paste
        case "name": return .name
        case "servers": return .servers
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
    /// **The manager's name, as the owner typed it on "Name your manager"**: the name that the page had the last time
    /// on this Mac, or the suggested one. It is kept on this Mac from Continue on, so a new start of the app does not
    /// ask for it again with an empty field.
    var managerName = UserDefaults.standard.string(forKey: FirstRunModel.nameKey) ?? ManagerName.suggested
    static let nameKey = "firstRunManagerName"
    /// The owner went on from "Name your manager" in this first run: its pages show their steps, and the hub's
    /// installer gets the name. False for a first run that opens on a later page with no name (`-firstRunStep`):
    /// its manager is `manager`, as before. The way of the owner's own agent passes "Name your manager" too
    /// (`agentStartedGuide`, and `setup_show` with `name`).
    private(set) var named = false

    /// **The name that the hub's installer gets** (`hub.sh --manager-name`): the typed name by the installer's own
    /// rule (`ManagerName.agentName`), or none for a first run that did not ask, whose manager is `manager` as before.
    var hubName: String? { named ? ManagerName.agentName(managerName) : nil }

    /// Continue of "Name your manager": on to "Your fleet's servers".
    func nameChosen() {
        guard ManagerName.agentName(managerName) != nil else { return }
        UserDefaults.standard.set(ManagerName.shown(managerName), forKey: Self.nameKey)
        named = true
        start(.servers)
    }

    /// **The step of the slider of "Your fleet's servers"**: the one that the page had the last time on this Mac, or
    /// the middle one. It is kept on this Mac from Continue on. "1 server" changes the install (`oneServer`). The other
    /// two steps build the same fleet at first, the hub's server and the manager's own: they differ when the second
    /// agent comes. The hub's installer gets each step (`InstallPlan.hub`'s `shape`), and a hub with the feature
    /// `fleet_shape` keeps it; this Mac keeps the choice too, for the page's next opening.
    var serversStep = UserDefaults.standard.string(forKey: FirstRunModel.stepKey).flatMap(ServersStep.init(rawValue:)) ?? .two
    static let stepKey = "firstRunServersStep"

    /// **One server for all**: the owner came through the slider's page and chose its first step. The hub's installer
    /// then gets the word for it, puts the manager on the hub's own server, and the manager's setup has no server page.
    var oneServer: Bool { shaped && serversStep == .one }
    /// The owner went on from "Your fleet's servers" in this first run: `setup_state` gives the choice from then on.
    private(set) var shaped = false

    /// Continue of "Your fleet's servers": on to the VPS page, with this Mac's network and the fleet's key first when
    /// they are missing, as after a press on a card. Then the VPS page's own press needs neither, and the steps on
    /// Back's line never go back.
    func serversChosen() {
        UserDefaults.standard.set(serversStep.rawValue, forKey: Self.stepKey)
        shaped = true
        choose(.cloud)
    }

    /// Back from the network's page and from the key's: to "Your fleet's servers" when they stand between it and the
    /// VPS page, else to the VPS page, whose card brought them.
    var backFromNetwork: Step { named && after == .cloud ? .servers : .cloud }

    /// **The steps on Back's line** (`SetupProgress`, `FirstRunSteps.of`): for the pages of the welcome page's first
    /// way. `page` is the page's name of `setup_state`.
    func progress(on page: String) -> SetupProgress? {
        let steps = FirstRunSteps.inFlow
        guard let step = FirstRunSteps.of(page: page, named: named), let index = steps.firstIndex(of: step) else { return nil }
        return SetupProgress(names: steps.map(\.name), current: index)
    }
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
    /// taken. **The first pages ask again while they show** (`looksEvery`; the welcome page, the page after its press
    /// and the VPS page, `WelcomeRules.looksForAFleet`), so a fleet that the owner's own agent installs meanwhile
    /// connects with nothing pasted: that agent claims the hub from this Mac. Nothing changes while the owner has gone
    /// on from those pages. **On the VPS page nothing changes after an install of this wizard began**, so that it never
    /// connects to the hub that the install left half made; back on the welcome page and the page after its press the
    /// wizard is at its start again (`WelcomeRules.looksForAFleet`).
    ///
    /// **With a fleet connected already it does nothing** (`fleet`: the welcome page of an unfinished setup): it
    /// connects to no hub a second time, and the window never goes to this wizard's last page.
    func findFleet(store: FleetStore, fleet: Bool = false) async {
        guard WelcomeRules.looksForAFleet(on: page, began: began, busy: busy, fleet: fleet), macReady == true,
              looksForAFleet, let status = await MacNetwork.status(), looksForAFleet else { return }
        // **A hub that "Start again" left alive is passed over** (`StartAgain.LeftHubs`): it serves this Mac still,
        // so this search would take the app back to the fleet that the owner just left. It is passed over by its
        // address and by each name that its device has. A connect that the owner asks for himself takes the hub out
        // of that list (`FleetStore.connect`).
        let left = StartAgain.LeftHubs.addresses(among: FleetOnTailscale.devices(in: status),
                                                 dnsNames: StartAgain.LeftHubs.dnsNames(in: status))
        let ask: @Sendable (URL) async -> Bool = { hub in
            guard !left.contains(hub.host ?? "") else { return false }
            return await FleetOnTailscale.answersHealth(hub)
        }
        guard let hub = await FleetOnTailscale.findHub(json: status, ask: ask),
              (try? await HubClient().stateReading(at: hub)) != nil, looksForAFleet else { return }
        await connect(to: hub.absoluteString, store: store, again: false)
    }

    /// The page looks for a fleet now (`WelcomeRules.looksForAFleet`).
    var looksForAFleet: Bool { WelcomeRules.looksForAFleet(on: page, began: began, busy: busy) }

    /// A new build of the app may go in by itself now (`WelcomeRules.atRest`).
    var atRest: Bool { WelcomeRules.atRest(on: page, began: began, busy: busy) }

    /// The second way of the welcome page: the prompt goes on the clipboard, and its page shows it.
    func letAgent() {
        copyPrompt()
        start(.paste)
    }

    func copyPrompt() {
        copyMessage(AgentPrompt.shown)
        promptCopied = true
    }

    /// **The owner's own agent started the guide** (`founderizer-cli guide`, `OwnerGuide.started`): on the welcome page
    /// or the page after its press, with no connect of this wizard running, the wizard goes on (`WelcomeRules.firstWay`):
    /// in a first run to "Name your manager", as the owner's own press on the welcome page's first way does, or, with
    /// a fleet whose setup never finished (`fleet`), out of this wizard to the manager's setup, which its caller
    /// opens. The way says that the app comes to the front. Any other state keeps its page: nil.
    func agentStartedGuide(fleet: Bool = false) -> WelcomeRules.FirstWay? {
        guard WelcomeRules.guideTakesTheApp(on: page, busy: busy) else { return nil }
        let way = WelcomeRules.firstWay(fleet: fleet)
        if way == .firstRun { start(.name) }
        return way
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
        if case .refusal(let refused)? = error as? HubError, refused.status != 404 { return reach.says }
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
        // A program installed while the wizard showed counts when the welcome page shows again.
        if step == .welcome { foundPrograms = AgentPrograms.found() }
        // The first run starts over on its welcome page: no way is taken, so no name and no layout are chosen. The
        // two pages keep what he typed and set.
        if step == .welcome { named = false; shaped = false }
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
    /// **The fleet has its hub already, and its setup never finished** (`FleetStore.welcomeCovers`): the wizard shows
    /// only the welcome page and the page after its press, in front of the manager's setup, and both ways lead there.
    var resumes = false
    /// `setup_show`'s answer to an ask for the VPS page while a fleet exists (the words of the lane of the link).
    static let noNamePage = "The fleet has its hub and its manager already, so the page name does not show here: "
        + "the app shows the manager's setup."
    @Environment(\.openWindow) private var openWindow
    private var install: MachineInstallModel { store.installModel() }

    var body: some View {
        SetupPage(progress: model.progress(on: pageName)) { backLink } step: { screens }
        // The first pages read this Mac and look for a fleet again and again while they show (`FirstRunModel.findFleet`,
        // which `WelcomeRules.looksForAFleet` decides); no other page of the wizard does. "Name your manager" reads
        // this Mac only, so that its Continue knows if the network's page comes next.
        .task {
            while !Task.isCancelled {
                // "Name your manager" reads this Mac and looks for a fleet as the VPS page does: its Continue must know
                // if the network's page comes next, and the owner's own agent can install a hub while the page shows.
                if WelcomeRules.atStart(model.page) || model.page == .cloud || model.page == .name {
                    // A fleet that is connected already needs no read of this Mac's network and no look for a fleet.
                    if !resumes { await model.readMac() }
                    await model.findFleet(store: store, fleet: resumes)
                }
                do { try await Task.sleep(for: FirstRunModel.looksEvery) } catch { return }
            }
        }
        .task { hold(model.holdsWindow) }
        .onChange(of: model.holdsWindow) { _, holds in hold(holds) }
        // **The first pages at rest** (`AppUpdatePolicy.setupHolds`, `WelcomeRules.atRest`): before a hub answers, the
        // only time a new build of this app goes in by itself, because its restart then takes nothing away. Never on the
        // page after the press, where the owner waits for their agent.
        .onChange(of: model.atRest, initial: true) { _, rest in if window { store.updates.setupAtRest = rest } }
        .onDisappear { if window { store.updates.setupAtRest = false } }
        // **The owner's own agent started the guide** (`founderizer-cli guide`): the window's wizard goes on to "Name
        // your manager" and the app comes to the front, only in the states that `WelcomeRules.guideTakesTheApp` names. The copy
        // that Settings shows before a hub does nothing, so one notification moves one wizard. **With a fleet whose
        // setup never finished** the sign ends the welcome page for this start of the app, and the window shows the
        // manager's setup: a second sign finds no wizard and does nothing.
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name(OwnerGuide.started))) { _ in
            guard window, let way = model.agentStartedGuide(fleet: resumes) else { return }
            if way == .managerSetup { store.passWelcome() }
            comeToFront()
        }
        // **What the owner's own agent reads, and the page that it asks to see** (`setup_state` and `setup_show` on the
        // link, `SetupChannel.swift`): the window's wizard keeps what it shows in the store, and takes the ask.
        .onChange(of: setupFirstRun, initial: true) { _, now in if window { store.setupSnapshot = now } }
        .onAppear { if window, cloud.onState == nil { cloud.onState = SetupChannel.reports(to: store, \.firstRunBuild) } }
        .onChange(of: store.setupAsk?.id, initial: true) { _, _ in take(store.setupAsk) }
        .onDisappear {
            guard window else { return }
            store.setupSnapshot = .none
            if store.setupAsk?.outcome == nil { store.setupAsk?.outcome = .refused(SetupChannel.windowWent) }
        }
    }

    /// **The title and the wait of one page, from one source** (round 2, T2): the page's `SetupStep` shows `title` and
    /// moves its words while `waits`, and `setup_state` gives `key`, the string table's key of that title (nil for a title
    /// that is no key, a server's address), and `waits` as its `works`.
    private struct Head {
        let title: String
        let key: String?
        let waits: Bool
    }

    private var networkHead: Head {
        net.pressed ? Head(title: String(l10n: "Waiting for Tailscale"), key: "Waiting for Tailscale", waits: true)
            : Head(title: String(l10n: "Connect Tailscale"), key: "Connect Tailscale", waits: false)
    }

    private var keyHead: Head {
        net.busy ? Head(title: String(l10n: "Connecting your network"), key: "Connecting your network", waits: true)
            : Head(title: String(l10n: "Your Tailscale key"), key: "Your Tailscale key", waits: false)
    }

    /// A provider's server is made (the page `building`).
    private var cloudBuilds: Bool { cloud.stage == .making || cloud.stage == .joining }

    private func tokenHead(_ provider: CloudProvider) -> Head {
        let choosing = cloud.stage == .choosing
        let waits = cloudBuilds || (choosing && cloud.offer == nil)
        if cloudBuilds { return Head(title: String(l10n: "Building your fleet"), key: "Building your fleet", waits: waits) }
        // After the token was taken, a stop leaves the page the server's: its title too.
        if choosing || cloud.tokenTaken {
            return Head(title: String(l10n: "Your hub's server at \(provider.name)"), key: "Your hub's server at %@",
                        waits: waits)
        }
        return Head(title: String(l10n: "Your \(provider.name) token"), key: "Your %@ token", waits: waits)
    }

    private var vpsHead: Head {
        switch vps.phase {
        case .address: Head(title: String(l10n: "Your VPS"), key: "Your VPS", waits: false)
        case .checking: Head(title: String(l10n: "Checking \(vps.host)"), key: "Checking %@", waits: true)
        case .waiting: Head(title: String(l10n: "Waiting for \(vps.host)"), key: "Waiting for %@", waits: true)
        case .password:
            Head(title: String(l10n: "Password for \(vps.target?.user ?? "root")@\(vps.host)"), key: "Password for %@@%@",
                 waits: false)
        case .ready, .stopped: Head(title: vps.host, key: nil, waits: false)
        }
    }

    /// The install's page while it runs or after it ran; "Your server" before.
    private var machineHead: Head {
        guard install.running || install.checklist != nil || install.failure != nil else {
            return Head(title: String(l10n: "Your server"), key: "Your server", waits: false)
        }
        // **No "Your fleet is up" for a frame before the app** (fix round 3, item 49): when the app goes on by itself, the
        // moving title stands until it does. **A stop has a true title** (item 51): the title said "Installing your hub
        // on 203.0.113.9" over the stop.
        let checked = !install.running && install.checklist != nil
        let connecting = checked && (store.state == nil || passed && !offersRestore)
        let stopped = !install.running && install.failure != nil
        let waits = install.running || connecting
        if stopped { return Head(title: String(l10n: "Your hub did not install"), key: "Your hub did not install", waits: waits) }
        if connecting { return Head(title: String(l10n: "Connecting to your hub"), key: "Connecting to your hub", waits: waits) }
        if checked {
            return passed ? Head(title: String(l10n: "Your fleet is up"), key: "Your fleet is up", waits: waits)
                : Head(title: String(l10n: "Your hub is installed"), key: "Your hub is installed", waits: waits)
        }
        return Head(title: String(l10n: "Building your fleet"), key: "Building your fleet", waits: waits)
    }

    private var addressHead: Head {
        model.busy ? Head(title: String(l10n: "Checking your fleet"), key: "Checking your fleet", waits: true)
            : Head(title: String(l10n: "Your hub's address"), key: "Your hub's address", waits: false)
    }

    private var doneHead: Head {
        // **"Your fleet is up" only with the offer that stays under it** (fix round 3, item 49): on a hub with work it stood
        // for 1-2 frames before the app; the moving words stand until the app takes the window.
        allProved && offersRestore ? Head(title: String(l10n: "Your fleet is up"), key: "Your fleet is up", waits: false)
            : Head(title: String(l10n: "Checking your fleet"), key: "Checking your fleet", waits: true)
    }

    /// **The first run as `setup_state` gives it**: the page by its fixed name (`FirstRunPage.ofStep`), and each page's
    /// title key and wait from its `Head`, the one source that its `SetupStep` reads too. The welcome page, the page
    /// after its press, the VPS page and the restore page have fixed titles and no moving words: their work is the
    /// wizard's connect (`model.busy`) and the restore's.
    private var setupFirstRun: SetupFirstRun {
        var head: Head?, name = "", title: String?, works = false
        var provider: String?
        switch model.step {
        case .welcome: (name, title, works) = ("welcome", "Your own team of AI agents", model.busy)
        case .paste: (name, title, works) = ("paste", "Paste this in %@", model.busy)
        case .name: (name, title, works) = ("name", "Name your manager", false)
        case .servers: (name, title, works) = ("servers", "Your fleet's servers", false)
        case .network: (name, head) = ("network", networkHead)
        case .key: (name, head) = ("key", keyHead)
        case .cloud: (name, title, works) = ("cloud", "A VPS for your fleet", model.busy)
        case .token(let chosen):
            (name, head) = (cloudBuilds ? "building" : "token", tokenHead(chosen))
            provider = chosen.rawValue
        case .vps: (name, head) = ("vps", vpsHead)
        case .machine: (name, head) = ("machine", machineHead)
        case .installing: (name, head) = ("installing", machineHead)
        case .address: (name, head) = ("address", addressHead)
        case .done: (name, head) = ("done", doneHead)
        case .restore: (name, title, works) = ("restore", "Restore a copy", putBack.running)
        }
        if let head { (title, works) = (head.key, head.waits) }
        let page = name == "building" ? FirstRunPage.building : FirstRunPage.ofStep[name]
        return SetupFirstRun(shows: true, page: page, title: title, works: works, began: model.began,
                             holdsWindow: model.holdsWindow, provider: provider,
                             atStart: WelcomeRules.atStart(model.page),
                             layout: model.shaped ? FirstRunLayout(rawValue: model.serversStep.rawValue) : nil)
    }

    /// The page's name, as `setup_state` gives it and as the steps on Back's line read it (`FirstRunSteps.of`): a
    /// step's own name, and `building` for a provider's page while its server is made.
    private var pageName: String {
        switch model.step {
        case .welcome: "welcome"
        case .paste: "paste"
        case .name: "name"
        case .servers: "servers"
        case .network: "network"
        case .key: "key"
        case .cloud: "cloud"
        case .token: cloudBuilds ? "building" : "token"
        case .vps: "vps"
        // "Your server" before an install; the install's own page once it runs, ran or stopped.
        case .machine: install.running || install.checklist != nil || install.failure != nil ? "installing" : "machine"
        case .installing: "installing"
        case .address: "address"
        case .done: "done"
        case .restore: "restore"
        }
    }

    /// **A page that the owner's own agent asked to see** (`setup_show`): checked again here, because the wizard may have
    /// moved since the link checked it. It changes the page only from a start page (welcome, the page after its press,
    /// the VPS page), where nothing typed is lost, and asks for the front. It presses nothing. **Its two pages are the
    /// welcome page and "Name your manager"**, the first page of the first way: the VPS page comes after that page's
    /// Continue, so the way of the owner's own agent is the way of the owner's own press.
    private func take(_ ask: SetupAsk?) {
        guard window, let ask, ask.outcome == nil else { return }
        guard ask.page == .welcome || ask.page == .name else {
            store.setupAsk?.outcome = .refused(SetupShow.pageWords)
            return
        }
        // With a fleet whose setup never finished this wizard has no page "Name your manager": the fleet has its
        // manager already. The link's own check lets the ask pass from a start page, so it is refused here, in words.
        if resumes, ask.page == .name {
            store.setupAsk?.outcome = .refused(Self.noNamePage)
            return
        }
        if let words = SetupShow.refusal(page: ask.page.rawValue, seen: ask.seen, firstRun: setupFirstRun) {
            store.setupAsk?.outcome = .refused(words)
            return
        }
        // The page that shows already changes nothing (round 3, P3); from one start page to another as Back does.
        if SetupShow.changesPage(to: ask.page.rawValue, from: setupFirstRun) {
            model.start(ask.page == .welcome ? .welcome : .name)
        }
        store.setupSnapshot = setupFirstRun
        store.setupAsk?.outcome = .shown
        comeToFront()
    }

    /// **The app comes to the front by itself, once** (the owner's "Yes" of 14 November 2026 to "May the app come to
    /// the front by itself when your own agent needs you there?"): `AppFront.come`, the one function that the link's
    /// `setup_show` uses too, so that a check on a real window changes how it asks in one place.
    private func comeToFront() {
        AppFront.come { openWindow(id: "fleet") }
    }

    /// The window belongs to the wizard until the owner leaves it.
    private func hold(_ holds: Bool) { if window { store.firstRunHolds = holds } }

    /// **Into the app, at the manager's chat**, and the wizard is done. Every way out of the wizard goes through here.
    /// The manager is the fleet's one agent and is not signed in yet, so its chat is its setup's two provider cards
    /// (`AgentSetupWizard`): the step that makes the first answer possible (D-3, the owner's yes of 28 October 2026;
    /// both providers since 4 November 2026).
    private func finish() {
        store.firstRunHolds = false
        let manager = store.state?.agents.first { $0.role == "manager" }?.name ?? "manager"
        // **A fleet on one server**: the installer of this first run put the manager on the hub's own server, so this
        // Mac never saw it with no server. Its first setup still fills the window and shows its steps, as the setup
        // of a manager that gets its first server does, until it runs (`FleetStore.noteFirstSetup`).
        if model.began, model.oneServer { store.noteFirstSetup(of: manager) }
        store.destination = .agent(manager)
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
        case .welcome:
            WelcomePage(programs: model.programs, setUp: { setUp() }, letAgent: { model.letAgent() })
        case .paste: PastePage(programs: model.programs, copied: model.promptCopied) { model.copyPrompt() }
        case .name: NameManagerPage(name: $model.managerName) { model.nameChosen() }
        // The fleet is the hub and the manager at this point: the page draws the agents to come itself.
        case .servers:
            FleetServersPage(plan: FleetPlan(manager: model.managerName, agents: []), step: $model.serversStep) {
                model.serversChosen()
            }
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

    /// **"Set it up yourself" goes on where the setup stands** (`WelcomeRules.firstWay`): to the first run's own next
    /// page of a Mac with no fleet ("Name your manager"), or, with a fleet whose setup never finished, out of this
    /// wizard: the window then shows the manager's setup at its own page ("Manager's server", or its AI provider when
    /// a server joined for it already). A fleet has its manager and its name, so "Name your manager" never shows there.
    private func setUp() {
        switch WelcomeRules.firstWay(fleet: resumes) {
        case .firstRun: model.start(.name)
        case .managerSetup: store.passWelcome()
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

    /// The welcome page is the first page and has no Back; the VPS page has Back to it since 14 November 2026.
    @ViewBuilder private var backLink: some View {
        if model.step != .welcome && !(model.step == .restore && putBack.running) && !runs {
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
        case .name: model.start(.welcome)
        case .servers: model.start(.name)
        case .network, .key: model.start(model.backFromNetwork)
        case .machine, .address: model.start(.cloud)
        case .token: cloud.cancel(); model.start(.cloud)
        case .vps: vps.reset(); model.start(.cloud)
        // From a stopped install, to its form with what he typed (fix round 3, item 51): Back left the stop in place.
        case .installing: install.again(); vps.reset(); model.start(.cloud)
        case .restore: model.start(.done)
        case .done: model.start(.cloud)
        // The VPS page goes back to "Your fleet's servers" when the owner came through it. Else it and the page after
        // the press go back to the welcome page; the welcome page has no Back.
        case .cloud where model.named: model.start(.servers)
        case .cloud, .paste, .welcome:
            if WelcomeRules.back(from: model.page) == .welcome { model.start(.welcome) }
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
        SetupStep(title: networkHead.title, waits: networkHead.waits) { NetworkMark() } content: {
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
        SetupStep(title: keyHead.title, waits: keyHead.waits) { NetworkMark() } content: {
            if !net.busy {
                // What he does at Tailscale comes before the paste, so its steps stand over the field.
                SetupSteps.tailscaleKey
                PasteField(placeholder: String(l10n: "Paste it here"), text: $net.keyText, accepts: { $0.hasPrefix("tskey-api-") }) {
                    Task { if await net.sendKey() { model.afterKey(); opensChoice() } }
                }
                .accessibilityIdentifier("first-run-tailscale-key")
            }
            if let lines = net.linesToAdd, let asks = net.asks {
                PolicyLines(says: asks, lines: lines, copied: net.copied) { net.copyLines() }
            }
            if let failure = net.failure { SetupWarning(failure) }
        }
    }

    // MARK: the fleet's VPS

    private var serverMark: some View { IconTile(symbol: "server.rack", size: SetupMetrics.mark).accessibilityHidden(true) }

    /// **A VPS for the fleet, the page of the welcome page's first way, with Back to it: a card for each provider and
    /// one for any other VPS** (the owner,
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
        // The install keeps the name for its Try again, which runs the same install.
        install.managerName = model.hubName
        install.oneServer = model.oneServer
        install.shape = model.shaped ? model.serversStep : nil
        install.installHub(store: store)
        model.start(.installing)
    }

    private func token(_ provider: CloudProvider) -> some View {
        let building = cloudBuilds
        let choosing = cloud.stage == .choosing
        let head = tokenHead(provider)
        return SetupStep(title: head.title, waits: head.waits) {
            // The provider's own logo over its pages, as Add server has it (the owner, 10 November 2026).
            CloudMark(provider: provider, size: SetupMetrics.mark)
        } content: {
            if building {
                CloudBuilding(stage: cloud.stage, provider: cloud.provider, showsStatus: true)
            } else if choosing {
                CloudChoice(cloud: cloud, job: .hub, fleet: [], makeNew: { cloud.makeNew { startInstall($0) } },
                            use: useExisting)
            } else if !cloud.tokenTaken {
                // A token that the provider took is never asked for again on this page (`FleetCloudModel.tokenTaken`).
                SetupSteps.token(provider)
                PasteField(placeholder: String(l10n: "Paste it here"), text: $cloud.tokenText,
                           accepts: { $0.count >= 20 && !$0.contains(" ") }) {
                    cloud.sendToken(provider, use: .hub)
                }
                .accessibilityIdentifier("first-run-cloud-token")
            }
            // While the list shows, its own press carries the line (`CloudChoice`).
            if let failure = cloud.failure, !choosing || cloud.offer == nil { SetupWarning(failure) }
        }
    }

    /// **Any VPS, by its address** (the owner, 4 November 2026: "maybe users will only have ssh access to that server..
    /// with nothing else installed"): one field, the check, the password once when the VPS asks for one, then one
    /// Install press with the line of what changes, or one orange line of why not.
    @ViewBuilder private var vpsStep: some View {
        switch vps.phase {
        case .address:
            SetupStep(title: vpsHead.title, waits: vpsHead.waits) { serverMark } content: {
                SetupField(placeholder: String(l10n: "Address"), text: $vps.addressText) { vps.tailnet = model.mac?.tailnet; vps.check(job: .hub) }
                    .accessibilityIdentifier("first-run-vps-address")
            }
        case .checking:
            SetupStep(title: vpsHead.title, waits: vpsHead.waits) { serverMark }
        case .waiting(let why):
            SetupStep(title: vpsHead.title, waits: vpsHead.waits) { serverMark } content: {
                Text(why).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        case .password:
            SetupStep(title: vpsHead.title, waits: vpsHead.waits) {
                IconTile(symbol: "lock", size: SetupMetrics.mark).accessibilityHidden(true)
            } content: {
                SetupSecureField(placeholder: String(l10n: "Password"), text: $vps.passwordText) { vps.givePassword(job: .hub) }
                    .accessibilityIdentifier("first-run-vps-password")
                Text("Used once, to add this Mac's key. Never kept.").foregroundStyle(FleetStyle.muted)
            }
        case .ready(let summary, let changes):
            SetupStep(title: vpsHead.title, waits: vpsHead.waits) { serverMark } content: {
                Label { Text(summary) } icon: { Image(systemName: "checkmark").foregroundStyle(.green) }
                    .foregroundStyle(FleetStyle.text)
                Button("Install") { if let target = vps.target { startInstall(target, sudo: vps.sudoPassword) } }
                    .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("first-run-vps-install")
                Text(changes).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        case .stopped(let why):
            SetupStep(title: vpsHead.title, waits: vpsHead.waits) { serverMark } content: {
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
            // The title and its moving words: `machineHead`.
            SetupStep(title: machineHead.title, waits: machineHead.waits) { mark } content: {
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
            SetupStep(title: machineHead.title, waits: machineHead.waits) { mark } content: {
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
        SetupStep(title: addressHead.title, waits: addressHead.waits) { mark } content: {
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
        // The title and its moving words: `doneHead`.
        return SetupStep(title: doneHead.title, waits: doneHead.waits) { mark } content: {
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
