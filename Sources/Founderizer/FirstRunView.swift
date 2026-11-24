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
/// `founderizer-cli guide`, the app goes on to "Help improve Founderizer", the first page of the first way, and comes to
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
        /// "Help improve Founderizer", the first page of the welcome page's first way, before "Name your manager" (the
        /// owner, 18 November 2026: "durng the very first onboarding, one of the first steps should be asking if they
        /// wnat to share diagnosis data", and "Yes, build it" to its picture): send error reports, or not.
        case errorReports
        /// "Name your manager", the page after "Help improve Founderizer" (the owner, 15 November 2026: "but
        /// initially we should ask the manager name? I would focus the onboarding in creating the manager", and "Yes,
        /// build it" to its picture).
        case name
        /// "<Name>'s AI provider", the manager's own page of its AI provider, after its name (the owner, 16 November
        /// 2026: "agent onboarding should ask first for the name and AI provider before the server page", and his yes
        /// of the same day to the one wizard's line of steps: Manager, AI provider, Servers, Network, VPS, Build).
        case aiProvider
        /// "Your fleet's servers", the slider from the lower cost to the more secure, after the manager's AI provider
        /// (his "where is the slider with price <> security we designed", and "Steps first", of 15 November 2026).
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
        case .welcome, .paste, .errorReports, .name, .aiProvider, .servers, .network, .machine, .key, .cloud, .token, .vps: false
        case .installing, .address, .done: true
        }
    }

    /// The screen this wizard opens on. It is the first screen, the welcome page, unless somebody asked for another one
    /// with `-firstRunStep <welcome|paste|errorReports|name|aiProvider|servers|cloud|network|key|vps|machine|done|address>`, which is how a screen of
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
        // The four pages of the first way before this Mac's network: each looks for a fleet, none is a start page,
        // and no new build of the app goes in by itself on any.
        case .errorReports, .name, .aiProvider, .servers: .name
        default: .other
        }
    }

    /// **Only the start's own arguments** (`UserDefaults.argumentDomain`), never a kept setting: a `defaults write` of
    /// this name would open each start of the app on that page, for example on the VPS page with no name asked.
    static var asked: Step? {
        switch UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["firstRunStep"] as? String {
        case "welcome": return .welcome
        case "paste": return .paste
        case "errorReports": return .errorReports
        case "name": return .name
        case "aiProvider": return .aiProvider
        case "servers": return .servers
        case "network": return .network
        case "machine": return .machine
        case "done": return .done
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
    var managerName = AppDefaults.store.string(forKey: FirstRunModel.nameKey) ?? ManagerName.suggested
    static let nameKey = "firstRunManagerName"
    /// The owner went on from "Name your manager" in this first run: its pages show their steps, and the hub's
    /// installer gets the name. False for a first run that opens on a later page with no name (`-firstRunStep`):
    /// its manager is `manager`, as before. The way of the owner's own agent passes "Name your manager" too
    /// (`agentStartedGuide`, and `setup_show` with `name`).
    private(set) var named = false

    /// **The name that the hub's installer gets** (`hub.sh --manager-name`): the typed name by the installer's own
    /// rule (`ManagerName.agentName`), or none for a first run that did not ask, whose manager is `manager` as before.
    var hubName: String? { named ? ManagerName.agentName(managerName) : nil }

    /// **The owner's answer on "Help improve Founderizer"** (`FirstRunReports`): true to send error reports, false not
    /// to, nil before the first answer on this Mac. This Mac keeps it, so that the card he chose keeps its check mark
    /// after Back and after a new start of the app, and gives it to the hub once the hub answers
    /// (`FirstRunReportsSender`). Read at each drawing, so that a press in another copy of this wizard shows too.
    var sendsReports: Bool? { FirstRunReports.chosen() }

    /// A press on a card of "Help improve Founderizer": on to "Name your manager".
    func reportsChosen(_ send: Bool) {
        FirstRunReports.choose(send)
        start(.name)
    }

    /// Continue of "Name your manager": on to the manager's AI provider.
    func nameChosen() {
        guard ManagerName.agentName(managerName) != nil else { return }
        AppDefaults.store.set(ManagerName.shown(managerName), forKey: Self.nameKey)
        named = true
        start(.aiProvider)
    }

    /// The cards of the page of the manager's AI provider, in their order: the programs that the manager runs (`hub.sh
    /// --runtime`), as the manager's own setup has them (`AgentSetupWizard`).
    static let aiChoices = ["codex", "claude"]
    /// **The manager's AI provider, as the owner chose it on its page**: the one that the page had the last time on this
    /// Mac, or none. It is kept on this Mac from the press on, so that the card that he chose keeps its check mark
    /// after Back and after a new start of the app.
    private(set) var aiProvider = AppDefaults.store.string(forKey: FirstRunModel.aiKey).flatMap {
        FirstRunModel.aiChoices.contains($0) ? $0 : nil
    }
    static let aiKey = "firstRunAIProvider"
    /// The owner went on from the page of the manager's AI provider in this first run.
    private(set) var choseAI = false
    /// **The AI provider that this first run gives on** (`claude` or `codex`), or nil when the owner did not go on from
    /// its page in this first run: `setup_state` gives it, the hub's installer gets it with "1 server" (`hub.sh
    /// --runtime`), and the manager's setup gets it after the build, so that it is asked once.
    var chosenAI: String? { choseAI ? aiProvider : nil }

    /// A press on a card of the manager's AI provider: on to "Your fleet's servers".
    func aiChosen(_ provider: String) {
        guard Self.aiChoices.contains(provider) else { return }
        aiProvider = provider
        AppDefaults.store.set(provider, forKey: Self.aiKey)
        choseAI = true
        start(.servers)
    }

    /// **The step of the slider of "Your fleet's servers"**: the one that the page had the last time on this Mac, or
    /// the middle one. It is kept on this Mac from Continue on. "1 server" changes the install (`oneServer`). The other
    /// two steps build the same fleet at first, the hub's server and the manager's own: they differ when the second
    /// agent comes. The hub's installer gets each step (`InstallPlan.hub`'s `shape`), and a hub with the feature
    /// `fleet_shape` keeps it; this Mac keeps the choice too, for the page's next opening.
    var serversStep = AppDefaults.store.string(forKey: FirstRunModel.stepKey).flatMap(ServersStep.init(rawValue:)) ?? .two
    static let stepKey = "firstRunServersStep"

    /// **One server for all**: the owner came through the slider's page and chose its first step. The hub's installer
    /// then gets the word for it, puts the manager on the hub's own server, and the manager's setup has no server page.
    var oneServer: Bool { shaped && serversStep == .one }
    /// The owner went on from "Your fleet's servers" in this first run: `setup_state` gives the choice from then on.
    private(set) var shaped = false

    /// **The first run's one press makes the manager's own server too** (slice 2 of the one wizard; the owner's "that is
    /// brilliant!" of 16 November 2026 to the build page's picture): on 2 servers and 1 per agent, when the owner came
    /// through the slider's page. Else the manager's setup makes it, as before.
    var makesManagersServer: Bool { shaped && serversStep.managersOwnServer }
    /// The manager's own server that this run made under the hood (`FirstRunView.makeManagersServer`): its name and its
    /// id at the provider from its build, then its name and its address on the private network once it is there.
    var managersServerMade: (name: String, id: String?, provider: CloudProvider)?
    var managersServer: FleetStore.MadeServer?
    /// The hub's address that the newest try of the hub's server gives (`StartAgain.hubAddress`), for which the
    /// manager's own server is kept.
    var managersHub: URL?
    /// **The provider of the manager's own server** (slice 2b of the one wizard, its capsule on "Your fleet"), when the
    /// owner chose another one than the hub's; nil: the hub's, also after the hub's changes.
    var managersProvider: CloudProvider?
    /// That provider's token page shows for the manager's own server, because this Mac holds no token of it yet.
    var managersToken: CloudProvider?
    /// **The manager's own server was refused on the build page** (slice 3, the picture's third element): the
    /// provider's words, over that server's capsule and its press, until a press makes it.
    var managersRefusal: String?
    /// The providers that answered "no room in your account" for the manager's own server in this run: none of them is
    /// opened again by itself.
    var managersFull: Set<CloudProvider> = []
    /// The steps to get more servers at Hetzner show in place of their link, under the refusal (`managersChoice`).
    var managersMoreShown = false

    /// Continue of "Your fleet's servers": on to the VPS page, with this Mac's network and the fleet's key first when
    /// they are missing, as after a press on a card. Then the VPS page's own press needs neither, and the steps on
    /// Back's line never go back.
    func serversChosen() {
        AppDefaults.store.set(serversStep.rawValue, forKey: Self.stepKey)
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
    /// in a first run to "Help improve Founderizer", as the owner's own press on the welcome page's first way does, or, with
    /// a fleet whose setup never finished (`fleet`), out of this wizard to the manager's setup, which its caller
    /// opens. The way says that the app comes to the front. Any other state keeps its page: nil.
    func agentStartedGuide(fleet: Bool = false) -> WelcomeRules.FirstWay? {
        guard WelcomeRules.guideTakesTheApp(on: page, busy: busy) else { return nil }
        let way = WelcomeRules.firstWay(fleet: fleet)
        if way == .firstRun { start(.errorReports) }
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
        // The first run starts over on its welcome page: no way is taken, so no name, no AI provider and no layout
        // are chosen. The three pages keep what he typed, pressed and set.
        if step == .welcome { named = false; choseAI = false; shaped = false; managersProvider = nil; managersToken = nil; managersRefusal = nil; managersFull = []; managersMoreShown = false }
        // So is the answer about error reports that no hub took yet: the way on asks for it again (`FirstRunReports`).
        if step == .welcome { FirstRunReports.forget() }
    }
}

/// **What the window's first run keeps while another page has the window** (the review of 17 November 2026): Settings,
/// which ⌘, opens in the middle of the first run, takes the window from the wizard, and a view's own state ends with the
/// view, while the provider's build, the install that its end starts and the manager's own server go on. The wizard
/// that came back then opened on its welcome page with none of that work, and its press made a second server. The
/// window's wizard takes its models from here, so the one that comes back is the same: on the same step, with the same
/// builds. The first run that is over drops them (`FirstRunView`'s `onDisappear`), and the next one opens on its
/// welcome page.
@MainActor @Observable
final class FirstRunWork {
    let model = FirstRunModel()
    /// This Mac's own private network.
    let networkModel = PrivateNetworkModel()
    /// This Mac on the private network, and the fleet's own Tailscale key.
    let net = FleetNetworkModel()
    /// The fleet's VPS, made at a provider, or any VPS by its address.
    let cloud = FleetCloudModel()
    let vps = FleetVPSModel()
    /// **The manager's own server, on 2 servers and 1 per agent** (`makeManagersServer`): its offer opens with the
    /// hub's, and the same press makes it.
    let managerCloud = FleetCloudModel()
    /// The manager's sign-in that the first run asks for at its end is on its way (`finish`).
    var signsIn = false
    /// **The server of the account that "Use this server" chose for the hub**, by its provider, its id and the address
    /// that its install goes to (its public one; for the hub's server that this Mac made, the one on the private
    /// network): the hub's install there proves its build record by the id (`MachineInstallModel.provenServer`).
    var chosenServer: (provider: CloudProvider, id: String, address: String)?
    /// **The join of the manager's own server while the hub installs** (slice 3 of the one wizard): a second install, to
    /// the new hub's address from its claim on (`MachineInstallModel.JoinHub`), which the store reads only at the hub's
    /// end (`FirstRunView.startManagersJoin`).
    let managerInstall = MachineInstallModel()
    /// The window went to the manager's setup (`leave`): no join of the manager's server starts after it.
    var handedOver = false
    /// The hub's server of this try came from the provider's build, whose part of the bar its install goes on from.
    var hubBuilt = false

    /// The window's own: its first wizard makes it, and each one after takes it, until `drop`.
    private static var window: FirstRunWork?
    static var kept: FirstRunWork {
        if let window { return window }
        // A new first run of the window, also at a start of the app: no answer of an earlier one waits for a hub.
        FirstRunReports.forget()
        let made = FirstRunWork()
        window = made
        return made
    }

    /// The first run is over: the next wizard of the window opens on its welcome page. Each way out of the first run
    /// drops it (`leave`, `FleetStore.forgetFleet`), and so does a wizard that the
    /// window leaves for a fleet that answers (`onDisappear`).
    static func drop() { window = nil }

    /// This work is the window's still: a build's end of a first run that is over holds no window (`startInstall`).
    static func isKept(_ work: FirstRunWork) -> Bool { window === work }
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
    /// **The wizard's models and its two values** (`FirstRunWork`): the window's wizard keeps them while another page has
    /// the window, and every other copy has its own. Each model has its own `State` too, for the fields' bindings.
    @State private var work: FirstRunWork
    @State private var model: FirstRunModel
    @State private var networkModel: PrivateNetworkModel
    @State private var net: FleetNetworkModel
    @State private var cloud: FleetCloudModel
    @State private var vps: FleetVPSModel
    @State private var managerCloud: FleetCloudModel
    /// **This Mac's network as the provider's page read it last** (`readNetwork`, for `hubAgain`): its devices; the
    /// addresses that no install of the hub goes to (a hub that "Start again" left alive, and a hub that refused this
    /// Mac); and the addresses whose hub that reading asked, so that no row is usable before its server's hub was
    /// asked.
    @State private var seen: (devices: [FleetOnTailscale.Device], never: Set<String>, asked: Set<String>) = ([], [], [])
    /// The addresses whose hub refused this Mac while the provider's page stays: a later reading that finds that hub
    /// silent (it starts again) does not offer its server.
    @State private var refusedHubs: Set<String> = []
    /// The list's choice went to a server that can take the hub's install again (`suggestHub`, `makeServer`): not
    /// again for this list, also when a press that its provider refused reads it anew. A list that opens again after
    /// the page's token field or after Back starts with no such choice made.
    @State private var suggestedHub = false
    /// A reading of the network ended while this list showed: the list's choice moves by itself no more (`readNetwork`).
    @State private var listRead = false
    /// **The two lines that this page puts over the press of its list** (`FleetCloudModel.stop`, as Add server's line of
    /// a hub that does not answer; the owner's yes of 18 November 2026 to each, with these words, at that place): a
    /// press on "Make the server" that chose the row of the hub's server and made nothing, and one that made nothing
    /// because this Mac is not on its private network (`makeServer`). The words of that row are his of the same day.
    private static var tookRow: String { String(l10n: "You already have this server. Nothing new was made.") }
    private static var offNetwork: String {
        String(l10n: "This Mac is not on your private network. Open Tailscale, then press again.")
    }
    private static var madeForHub: String { String(l10n: "Made for your hub") }
    /// **The page's third line over that press** (his yes of 18 November 2026 to this line, with these words, at that
    /// place: "A: say it at the press"): a server that this Mac made for a hub is in the list and its row cannot be
    /// taken, so the press would rent a second server while that one still costs money. The press says so and makes
    /// nothing, and the next press makes the server (`makeServer`, by the rule `EarlierServerLines`).
    private static func stillCosts(_ server: String, at provider: CloudProvider) -> String {
        String(l10n: "\(server) is still at \(provider.name) and still costs money. Press again to make a new server.")
    }
    /// A press on "Make the server" waits for its reading of the network (`makeServer`): the page's title shows the
    /// wait, and a second press does nothing. `makeAsked` counts the presses, and `makeTaken` the ones that the page's
    /// task took, as in Add server.
    @State private var asksNetwork = false
    @State private var makeAsked = 0
    @State private var makeTaken = 0
    /// **The join of the manager's own server while the hub installs** (slice 3 of the one wizard), kept with the rest
    /// (`FirstRunWork.managerInstall`).
    @State private var managerInstall: MachineInstallModel
    /// True in the window itself, false for the copy that Settings shows before there is a hub: only the window
    /// is held open for the wizard's last screens.
    var window: Bool
    /// **The fleet has its hub already, and its setup never finished** (`FleetStore.welcomeCovers`): the wizard shows
    /// only the welcome page and the page after its press, in front of the manager's setup, and both ways lead there.
    var resumes: Bool

    init(store: FleetStore, window: Bool = false, resumes: Bool = false) {
        self.store = store
        self.window = window
        self.resumes = resumes
        let work = window && !resumes ? FirstRunWork.kept : FirstRunWork()
        _work = State(initialValue: work)
        _model = State(initialValue: work.model)
        _networkModel = State(initialValue: work.networkModel)
        _net = State(initialValue: work.net)
        _cloud = State(initialValue: work.cloud)
        _vps = State(initialValue: work.vps)
        _managerCloud = State(initialValue: work.managerCloud)
        _managerInstall = State(initialValue: work.managerInstall)
    }
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
        // **The owner's own agent started the guide** (`founderizer-cli guide`): the window's wizard goes on to "Help
        // improve Founderizer" and the app comes to the front, only in the states that `WelcomeRules.guideTakesTheApp` names. The copy
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
        // The manager's own server's offer opens with the hub's (`opensManagersChoice`), also when the hub's opened
        // while another page had the window (`FirstRunWork`).
        .onChange(of: cloud.stage, initial: true) { _, _ in opensManagersChoice() }
        .onChange(of: cloud.tokenTaken) { _, _ in opensManagersChoice() }
        // The manager's own provider took its token (slice 2b): "Your fleet" again, with that provider's offer.
        .onChange(of: managerCloud.tokenTaken, initial: true) { _, taken in if taken { model.managersToken = nil } }
        // Its own provider refused the token that this Mac holds for it: that provider's token page again, for a new one.
        .onChange(of: managerCloud.stopped, initial: true) { _, stop in
            if stop == .token, let own = model.managersProvider, managerCloud.provider == own, !managerCloud.tokenTaken {
                model.managersToken = own
            }
            managersRefused(stop)
        }
        // The manager's server that a press on the build page made joins as soon as it is on the private network.
        .onChange(of: model.managersServer?.address) { _, address in
            if address != nil, install.claimedHubURL != nil { Task { await startManagersJoin() } }
        }
        // The provider's page reads this Mac's network for its list of the account's servers (`hubAgain`): at once
        // when the list shows, and every five seconds while it shows. Never while a build runs, which reads the
        // network itself.
        .task(id: choosesServer) {
            listRead = false
            while choosesServer, !Task.isCancelled {
                await readNetwork()
                do { try await Task.sleep(for: FirstRunModel.looksEvery) } catch { return }
            }
        }
        // A provider's page that is left, and one that comes, keeps nothing of the stay before: also another
        // provider's page that "Your fleet" opens in its place (`hubAt`), where the build's stage does not change.
        .onChange(of: asksProvider) { _, _ in suggestedHub = false; refusedHubs = []; seen = ([], [], []) }
        // A list that goes back to the token's field (another project's token, a list that the page gave up reading)
        // is another list when it comes again. A press that the provider refused goes through the build's stage, and
        // its list keeps the choice that was made.
        .onChange(of: cloud.stage) { before, now in if before == .choosing, now == .token { suggestedHub = false } }
        // The page's own task takes the press on "Make the server": a page that went meanwhile makes nothing.
        .task(id: makeAsked) { if makeAsked > makeTaken { makeTaken = makeAsked; await makeServer() } }
        // The page's own line over the press goes at the owner's next choice. The line of a press that chose a row
        // stays through that press's own choice, which goes from the new server to the row.
        .onChange(of: cloud.chosen) { before, _ in
            if cloud.failure == Self.offNetwork || (cloud.failure == Self.tookRow && before != nil)
                || earlierLines.has(cloud.failure) { cloud.stop(nil) }
        }
        // The manager's join, once the hub has claimed itself (`startManagersJoin`).
        .task(id: install.claimedHubURL) { await startManagersJoin() }
        .onDisappear {
            guard window else { return }
            store.setupSnapshot = .none
            if store.setupAsk?.outcome == nil { store.setupAsk?.outcome = .refused(SetupChannel.windowWent) }
            // **The first run is over** when the window went to a fleet that answers, with no hold of the wizard's: its
            // work goes, and the next first run opens on its welcome page. Settings, and a window that closes, keep it.
            if !resumes, store.state != nil, !store.firstRunHolds { FirstRunWork.drop() }
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

    /// **The first run's page "Your fleet"** (slice 2 of the one wizard): the fleet that the one press makes, for an
    /// owner who came through the slider's page and whose account has no server of its own. An account with servers
    /// keeps its list, where the owner can take one of them for the hub.
    private var showsFleet: Bool { model.shaped && cloud.existing.isEmpty }

    private func tokenHead(_ provider: CloudProvider) -> Head {
        if let other = model.managersToken {
            return Head(title: String(l10n: "Your \(other.name) token"), key: "Your %@ token",
                        waits: managerCloud.stage == .choosing)
        }
        let choosing = cloud.stage == .choosing
        // The page "Your fleet" waits for the offer of the manager's own server too.
        let managers = showsFleet && model.makesManagersServer && managerCloud.offer == nil
        let waits = cloudBuilds || asksNetwork || (choosing && (cloud.offer == nil || managers))
        if cloudBuilds { return Head(title: String(l10n: "Building your fleet"), key: "Building your fleet", waits: waits) }
        // After the token was taken, a stop leaves the page the server's: its title too.
        if choosing || cloud.tokenTaken {
            if showsFleet { return Head(title: String(l10n: "Your fleet"), key: "Your fleet", waits: waits) }
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
        if showsBuild, let other = model.managersToken {
            return Head(title: String(l10n: "Your \(other.name) token"), key: "Your %@ token",
                        waits: managerCloud.stage == .choosing)
        }
        if showsBuild { return Head(title: String(l10n: "Building your fleet"), key: "Building your fleet", waits: buildWaits) }
        // **The moving title stands until the app goes on by itself** (fix round 3, item 49; and no question of a copy
        // at the end since the owner's "Take it away" of 18 November 2026). **A stop has a true title** (item 51): the
        // title said "Installing your hub on 203.0.113.9" over the stop.
        let checked = !install.running && install.checklist != nil
        let connecting = checked && (store.state == nil || passed)
        let stopped = !install.running && install.failure != nil
        let waits = install.running || connecting
        if stopped { return Head(title: String(l10n: "Your hub did not install"), key: "Your hub did not install", waits: waits) }
        if connecting { return Head(title: String(l10n: "Connecting to your hub"), key: "Connecting to your hub", waits: waits) }
        if checked { return Head(title: String(l10n: "Your hub is installed"), key: "Your hub is installed", waits: waits) }
        return Head(title: String(l10n: "Building your fleet"), key: "Building your fleet", waits: waits)
    }

    private var addressHead: Head {
        model.busy ? Head(title: String(l10n: "Checking your fleet"), key: "Checking your fleet", waits: true)
            : Head(title: String(l10n: "Your hub's address"), key: "Your hub's address", waits: false)
    }

    /// The moving words stand until the app takes the window (fix round 3, item 49).
    private var doneHead: Head { Head(title: String(l10n: "Checking your fleet"), key: "Checking your fleet", waits: true) }

    /// **The first run as `setup_state` gives it**: the page by its fixed name (`FirstRunPage.ofStep`), and each page's
    /// title key and wait from its `Head`, the one source that its `SetupStep` reads too. The welcome page, the page
    /// after its press and the VPS page have fixed titles and no moving words: their work is the wizard's connect
    /// (`model.busy`).
    private var setupFirstRun: SetupFirstRun {
        var head: Head?, name = "", title: String?, works = false
        var provider: String?
        switch model.step {
        case .welcome: (name, title, works) = ("welcome", "Your own team of AI agents", model.busy)
        case .paste: (name, title, works) = ("paste", "Paste this in %@", model.busy)
        case .errorReports: (name, title, works) = ("errorReports", "Help improve Founderizer", false)
        case .name: (name, title, works) = ("name", "Name your manager", false)
        case .aiProvider: (name, title, works) = ("aiProvider", "%@'s AI provider", false)
        case .servers: (name, title, works) = ("servers", "Your fleet's servers", false)
        case .network: (name, head) = ("network", networkHead)
        case .key: (name, head) = ("key", keyHead)
        case .cloud: (name, title, works) = ("cloud", "A VPS for your fleet", model.busy)
        case .token(let chosen):
            (name, head) = (cloudBuilds ? "building" : "token", tokenHead(chosen))
            provider = (model.managersToken ?? chosen).rawValue
        case .vps: (name, head) = ("vps", vpsHead)
        case .machine: (name, head) = ("machine", machineHead)
        case .installing:
            (name, head) = ("installing", machineHead)
            if showsBuild, let other = model.managersToken { provider = other.rawValue }
        case .address: (name, head) = ("address", addressHead)
        case .done: (name, head) = ("done", doneHead)
        }
        if let head { (title, works) = (head.key, head.waits) }
        let page = name == "building" ? FirstRunPage.building : FirstRunPage.ofStep[name]
        return SetupFirstRun(shows: true, page: page, title: title, works: works, began: model.began,
                             holdsWindow: model.holdsWindow, provider: provider,
                             atStart: WelcomeRules.atStart(model.page),
                             layout: model.shaped ? FirstRunLayout(rawValue: model.serversStep.rawValue) : nil,
                             aiProvider: model.chosenAI.flatMap(FirstRunAI.init(rawValue:)))
    }

    /// The page's name, as `setup_state` gives it and as the steps on Back's line read it (`FirstRunSteps.of`): a
    /// step's own name, and `building` for a provider's page while its server is made.
    private var pageName: String {
        switch model.step {
        case .welcome: "welcome"
        case .paste: "paste"
        case .errorReports: "errorReports"
        case .name: "name"
        case .aiProvider: "aiProvider"
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
        }
    }

    /// **A page that the owner's own agent asked to see** (`setup_show`): checked again here, because the wizard may have
    /// moved since the link checked it. It changes the page only from a start page (welcome, the page after its press,
    /// the VPS page), where nothing typed is lost, and asks for the front. It presses nothing. **Its two pages are the
    /// welcome page and "Name your manager"**, which opens "Help improve Founderizer" first, the first page of the first
    /// way: the VPS page comes after the name's Continue, so the way of the owner's own agent is the way of the owner's
    /// own press.
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
        // **An ask for `name` opens "Help improve Founderizer"**, the page before it, as the owner's own press on the
        // welcome page's first way does: the owner answers it, and the agent never does.
        if SetupShow.changesPage(to: ask.page.rawValue, from: setupFirstRun) {
            model.start(ask.page == .welcome ? .welcome : .errorReports)
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
    /// The manager is the fleet's one agent and is not signed in yet, so its chat is its setup (`AgentSetupWizard`): the
    /// step that makes the first answer possible (D-3, the owner's yes of 28 October 2026; both providers since 4
    /// November 2026).
    ///
    /// **The manager's AI provider that the owner chose in this first run is not asked again** (`FirstRunModel.chosenAI`).
    /// A manager with no server gets it with its server: this Mac keeps it for the manager's setup
    /// (`FleetStore.noteProvider`), which gives the two together by itself, as after a press on that provider's card
    /// there. A manager that this first run's installer put on the hub's own server with that program ("1 server",
    /// `hub.sh --runtime`) gets its sign-in now, as a press on that card asks for it, so that its setup opens on the
    /// sign-in's steps. The window goes on when the hub has answered that request; a refusal leaves the setup on its
    /// provider's page, where a press asks again. A hub that does not take a write at that moment gets no request, and
    /// a second call while the request is on its way (the install page's own press) hands over at once
    /// (`FirstRunHandover`).
    private func finish() {
        let line = store.state?.agents.first { $0.role == "manager" }
        let manager = line?.name ?? "manager"
        // **A fleet on one server**: the installer of this first run put the manager on the hub's own server, so this
        // Mac never saw it with no server. Its first setup still fills the window and shows its steps, as the setup
        // of a manager that gets its first server does, until it runs (`FleetStore.noteFirstSetup`).
        if model.began, model.oneServer { store.noteFirstSetup(of: manager) }
        // **The manager's own server that the one press made** is kept for this hub, whichever try made it: the setup of a
        // manager with no server installs it by itself, and when no manager takes it (a later try chose 1 server), the
        // provider's list of Add server and "Start again" still know it as this fleet's.
        if model.managersServer != nil { keepManagersServer(for: store.hub) }
        // **A manager's server that joined from this run** (slice 3): its setup gives it to the manager with the chosen
        // provider by itself (`FleetStore.noteJoined`, `AgentSetupWizard.placeChosen`) and goes on to the sign-in.
        if line?.placed == false, managerInstall.checklist != nil, managerInstall.joinHub?.url == store.hub,
           let joined = managerInstall.server ?? model.managersServer?.name {
            store.noteJoined(joined, for: manager)
        } else if line?.placed == false {
            noteManagersServer()
        }
        switch FirstRunHandover.of(chosen: model.chosenAI, placed: line?.placed, runtime: line?.runtime,
                                   installedOneServer: model.began && model.oneServer, writes: store.canWrite,
                                   asked: work.signsIn) {
        case .keep(let provider):
            store.noteProvider(provider, for: manager)
        case .signIn(let provider):
            work.signsIn = true
            Task {
                // Only while the hub takes a write: the store then sends at once, and its request has its answer, or
                // the hub's client gives up, within that client's own limit. So the window always goes on.
                if store.canWrite {
                    _ = await store.save(.machineSignin(agent: manager, runtime: provider, replace: false), queue: false)
                }
                leave(to: manager)
            }
            return
        case .none: break
        }
        leave(to: manager)
    }

    /// The window is the app's again, at the manager's chat, where its setup shows until it runs.
    private func leave(to manager: String) {
        work.handedOver = true
        store.firstRunHolds = false
        store.destination = .agent(manager)
        // Also when Settings has the window during the sign-in's save, so that no wizard runs `onDisappear` now.
        FirstRunWork.drop()
    }

    /// The last press of an install. **No page of ours on the way** (D-3).
    private func openApp() { finish() }

    /// The wizard sits in the middle of the window: there is little on each screen, on purpose, and little looks
    /// abandoned at the top of a large one.
    @ViewBuilder private var screens: some View {
        switch model.step {
        case .welcome:
            WelcomePage(programs: model.programs, setUp: { setUp() }, letAgent: { model.letAgent() })
        case .paste: PastePage(programs: model.programs, copied: model.promptCopied) { model.copyPrompt() }
        case .errorReports: FirstRunReportsPage(marked: model.sendsReports) { model.reportsChosen($0) }
        case .name: NameManagerPage(name: $model.managerName) { model.nameChosen() }
        case .aiProvider: ManagerAIPage(name: model.managerName, marked: model.aiProvider) { model.aiChosen($0) }
        // The fleet is the hub and the manager at this point: the page draws the agents to come itself.
        case .servers:
            FleetServersPage(plan: FleetPlan(manager: model.managerName, agents: []), step: $model.serversStep) {
                model.serversChosen()
            }
        case .network: network
        case .machine, .installing: machine
        case .address: address
        case .done: done
        case .key: key
        case .cloud: cloudStep
        // The provider's build of the hub's server is the build page's first part, in a first run that came through
        // the slider's page.
        case .token(let provider):
            if cloudBuilds, model.shaped { buildPage } else { token(provider) }
        case .vps: vpsStep
        }
    }

    /// **"Set it up yourself" goes on where the setup stands** (`WelcomeRules.firstWay`): to the first run's own next
    /// page of a Mac with no fleet ("Help improve Founderizer"), or, with a fleet whose setup never finished, out of this
    /// wizard: the window then shows the manager's setup at its own page ("Manager's server", or its AI provider when
    /// a server joined for it already). A fleet has its manager and its name, so "Name your manager" never shows there.
    private func setUp() {
        switch WelcomeRules.firstWay(fleet: resumes) {
        case .firstRun: model.start(.errorReports)
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
        guard model.step == .installing else { return false }
        // The manager's token page on the build page has its own Back, to the choice (`back`).
        if model.managersToken != nil, showsBuild { return false }
        // Also while the build page waits for the manager's own server after the hub's end (`managersHolds`): Back there
        // went back to the VPS page and dropped the first run, with its hand-over. Only while the build page shows: a
        // stopped hub's install page keeps its Back, whose way clears the manager's.
        return install.running || managerInstall.running || managersHolds && showsBuild
    }

    /// The welcome page is the first page and has no Back; the VPS page has Back to it since 14 November 2026.
    @ViewBuilder private var backLink: some View {
        if model.step != .welcome && !runs {
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
        case .errorReports: model.start(.welcome)
        case .name: model.start(.errorReports)
        case .aiProvider: model.start(.name)
        case .servers: model.start(.aiProvider)
        case .network, .key: model.start(model.backFromNetwork)
        case .machine, .address: model.start(.cloud)
        // The token page of the manager's own provider goes back to "Your fleet", with the hub's provider for it.
        case .token where model.managersToken != nil:
            model.managersToken = nil
            model.managersProvider = nil
            managerCloud.cancel()
            opensManagersChoice()
        // The manager's offer goes with the hub's; a build of the manager's server that runs is never ended here.
        case .token:
            cloud.cancel()
            if managerCloud.stage == .choosing { managerCloud.cancel() }
            model.managersProvider = nil
            model.start(.cloud)
        case .vps: vps.reset(); model.start(.cloud)
        // The token page of the manager's provider on the build page: back to its choice, at the hub's provider.
        case .installing where model.managersToken != nil && showsBuild:
            model.managersToken = nil
            model.managersProvider = nil
            managerCloud.cancel()
            if let hubs = cloud.provider, managerCloud.holds(hubs) { managerCloud.open(hubs, use: .agent, lists: false) }
        // From a stopped install, to its form with what he typed (fix round 3, item 51): Back left the stop in place.
        case .installing:
            install.again()
            if !managerInstall.running { managerInstall.again() }
            model.managersToken = nil
            model.managersProvider = nil
            model.managersRefusal = nil
            // A refusal of the manager's server that its model still holds goes too: the next try opens it anew.
            if managerCloud.stage == .choosing, managerCloud.stopped == .making { managerCloud.cancel() }
            vps.reset(); model.start(.cloud)
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
    /// manager gets a server of its own on its own page. A copy of a fleet goes back on the new hub from Settings ›
    /// Backup: the first run asks no question of a copy (the owner, 18 November 2026: "Take it away").
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

    /// The provider whose page shows (its token, the wait for its list, the list, or its build), or none. "Your fleet"
    /// can put another provider's page in its place with no page between (`hubAt`).
    private var asksProvider: CloudProvider? {
        if case .token(let provider) = model.step { return provider }
        return nil
    }

    /// The list of the account's servers shows, with a server in it (`CloudChoice`'s list; the page "Your fleet" has none).
    private var choosesServer: Bool { asksProvider != nil && cloud.stage == .choosing && !cloud.existing.isEmpty }

    /// **The hub's server that this Mac made, whose install can run again** (`CloudExisting.hubAgain`; the owner's
    /// report of 14 November 2026: such a server stood grey in this list, and the one press left made a second paid
    /// server). From this Mac's own build records and its network as the page read it last (`seen`): never a server
    /// at the address of the hub that the app is connected to, and only a server whose hub that reading asked.
    private func hubAgain(_ server: CloudExisting) -> CloudReuse? {
        guard let provider = cloud.provider else { return nil }
        var except = seen.never
        if store.state != nil, let connected = store.hub.host { except.insert(connected) }
        guard case .install(let address)? = server.hubAgain(at: provider, builds: BuildRecords.shared.all(),
                                                            devices: seen.devices, except: except),
              seen.asked.contains(address) else { return nil }
        return .install(address: address)
    }

    /// **Reads this Mac's network for the list of the account's servers** (`seen`), and says whether it got a reading.
    /// Only an answer that says what the network is now is one (`FleetOnTailscale.live`: Tailscale runs, and this Mac
    /// is online in its network): a Tailscale that is stopped or signed out gives an old list of devices, which says
    /// nothing of a server now. No such answer, and a reading that the page ended, leave the reading before it, and
    /// the press on "Make the server" then makes nothing (`makeServer`). A server that the rule would take is asked for
    /// its hub first, and its row is usable only after that: a hub that answers its health within two seconds and
    /// then refuses this Mac two times in a row is not this Mac's to install over (the installer would start its
    /// services and its agents again), so its address is one of those that no install goes to, while the provider's
    /// page stays (`refusedHubs`). A hub that answers late, or with another answer, is not told apart from no hub.
    /// **The first reading that ends while a list shows moves that list's choice** (`suggestHub`). No later reading
    /// moves it by itself; a press on "Make the server" can (`makeServer`). A reading takes away the page's own line
    /// that is true no more: the one that said that this Mac is not on its network; the one of a press that chose
    /// a row, when that row can be taken no longer or is the choice no more; and the one of an earlier server, when a
    /// press would say it no more (`earlierLines`).
    @discardableResult private func readNetwork() async -> Bool {
        // The answer from its first `{`, as `live` reads it: a warning line can stand before it.
        guard let answer = await MacNetwork.status(), let brace = answer.firstIndex(of: "{"),
              let devices = FleetOnTailscale.live(in: answer), !Task.isCancelled else { return false }
        let status = String(answer[brace...])
        var never = StartAgain.LeftHubs.addresses(among: devices, dnsNames: StartAgain.LeftHubs.dnsNames(in: status))
            .union(refusedHubs)
        var asked = Set<String>()
        if let provider = cloud.provider {
            let builds = BuildRecords.shared.all()
            let taken = Set(cloud.existing.compactMap { server -> String? in
                guard case .install(let address)? = server.hubAgain(at: provider, builds: builds, devices: devices,
                                                                    except: never) else { return nil }
                return address
            })
            for address in taken.sorted() {
                asked.insert(address)
                guard let hub = StartAgain.hubAddress(onNetwork: address), await FleetOnTailscale.answersHealth(hub),
                      await MachineInstaller.readHub(at: hub) == .refuses,
                      await MachineInstaller.readHub(at: hub) == .refuses else { continue }
                never.insert(address)
            }
        }
        guard !Task.isCancelled else { return false }
        refusedHubs.formUnion(never.intersection(asked))
        seen = (devices, never, asked)
        let took = cloud.chosenServer.flatMap { hubAgain($0) } != nil
        // The line of an earlier server goes when a press would say it no more: that server's row can be taken now.
        if cloud.failure == Self.offNetwork || (cloud.failure == Self.tookRow && !took)
            || earlierLines.stale(cloud.failure) { cloud.stop(nil) }
        guard choosesServer else { return true }
        if !listRead { suggestHub() }
        listRead = true
        return true
    }

    /// **The list's first server that can take the hub's install again is chosen in place of the new one**, so that
    /// the press as it stands makes no second server (as Add server suggests a server in an agent's setup). Once for
    /// a list (`suggestedHub`), and never over a server that the owner chose. The owner's own choice of the new server
    /// before the first reading ended is not told apart from the list's first state.
    private func suggestHub() {
        guard choosesServer, !suggestedHub, cloud.chosen == nil,
              let first = cloud.existing.first(where: { hubAgain($0) != nil }) else { return }
        cloud.chosen = first.id
        suggestedHub = true
    }

    /// **The lines of the listed servers that this Mac's own record names as a hub's server that it made**
    /// (`stillCosts`; a record of its own build, by the provider's own id), in the list's order, each with whether
    /// its row can be taken as the page read the network last (`hubAgain`: not a server that is off, that is not
    /// online on this Mac's network, or whose address is one that no install goes to). The rule over them is
    /// `EarlierServerLines`.
    private var earlierLines: EarlierServerLines {
        guard let provider = cloud.provider else { return EarlierServerLines([]) }
        let builds = BuildRecords.shared.all()
        let made = cloud.existing.filter { server in
            builds.contains { $0.use == .hub && $0.provider == provider && $0.serverID == server.id }
        }
        return EarlierServerLines(made.map { (Self.stillCosts($0.name, at: provider), hubAgain($0) != nil) })
    }

    /// **The second click of a double click and the repeats of a held Return are no press on the list's button**
    /// (`SecondClick`, as on Needs you). The press after the line of an earlier server rents a server, and the press
    /// after a press that chose a row starts the hub's install on that row's server: each must be the owner's own
    /// next press, and not the rest of the press before it, whose reading of the network ends in a moment.
    private var pressRepeats: Bool {
        // A key event of this moment, as `SecondClick` asks of its click: a press that VoiceOver makes is no event,
        // and the app's last event then is an older one, which must not count.
        if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat,
           ProcessInfo.processInfo.systemUptime - event.timestamp < NSEvent.doubleClickInterval { return true }
        return SecondClick.isNow
    }

    /// "Make the server" in the list of the account's servers: the page's own task takes the press (`makeServer`).
    private func makeHub() { if !asksNetwork, !pressRepeats { makeAsked += 1 } }

    /// **The press on "Make the server"** (as Add server's press asks the hub first, `AddMachineView.makeServer`): when
    /// this Mac's own record names one of the listed servers as a hub's server that it made, each press reads the
    /// network first, and the page's title shows that it waits. A reading that shows that server as one that can take
    /// the hub's install again, on a list whose choice never went to such a server, chooses its row and makes nothing:
    /// the press is the owner's again, it says "Use this server", and the line over it says why nothing was made
    /// (`tookRow`), also when a reading that ended while the press waited chose that row. **With no reading, nothing
    /// is made** (the owner's yes of 18 November 2026: a Mac that is not on its network cannot tell whether that server
    /// can take the install again, and the press rented a second server): the line over the press says so
    /// (`offNetwork`), also on a list whose choice went to that row before, and no row is chosen from the reading
    /// before it. A press whose own reading did not come says that line also when another reading came a moment
    /// before: the line goes at the next reading. **With a reading, and such a server whose row cannot be taken, the
    /// press says that that server still costs money, and makes nothing** (`stillCosts`; the owner's yes of 18
    /// November 2026: that press rented a second server while the first still cost money): the press that finds that
    /// line over itself makes the server (`EarlierServerLines.says`; the second click of a double click is no press,
    /// `pressRepeats`). A line that went meanwhile (the owner's choice of a row, a line of the provider or of the network
    /// in its place) is said again. Else the new server is made: on a list whose choice
    /// went to the row before, the new server is the owner's own choice over it. A list with no such record makes the
    /// server at once. The server is made only on the list that was pressed on, with the new server still its choice.
    private func makeServer() async {
        guard !asksNetwork, cloud.stage == .choosing, cloud.chosen == nil else { return }
        // The page's own line of the press before goes at this one. `said` keeps it: the press that finds the line
        // of an earlier server over itself makes the server.
        let said = cloud.failure, earlier = earlierLines
        if said == Self.tookRow || said == Self.offNetwork || earlier.has(said) { cloud.stop(nil) }
        let made = !earlier.lines.isEmpty
        guard made else { return cloud.makeNew { work.hubBuilt = true; startInstall($0) } }
        asksNetwork = true
        defer { asksNetwork = false }
        let listing = cloud.listing
        let live = await readNetwork()
        guard !Task.isCancelled, cloud.stage == .choosing, cloud.listing == listing else { return }
        if live, cloud.chosen == nil, !suggestedHub, let first = cloud.existing.first(where: { hubAgain($0) != nil }) {
            cloud.chosen = first.id
            suggestedHub = true
        }
        // The list's choice is a row now, by this press or while it waited: the press makes nothing, and the line
        // says why when that row is the hub's server.
        if cloud.chosen != nil {
            if let server = cloud.chosenServer, hubAgain(server) != nil { cloud.stop(Self.tookRow) }
            return
        }
        guard live else { return cloud.stop(Self.offNetwork) }
        // A server of an earlier try whose row cannot be taken still costs money: the press says so and makes
        // nothing, until a press finds that line over itself.
        if let line = earlierLines.says(over: said) { return cloud.stop(line) }
        cloud.makeNew { work.hubBuilt = true; startInstall($0) }
    }

    /// **A server of the account, chosen in place of a new one**: the same check and the same Install press as Other
    /// VPS, at its public address. **The hub's server that this Mac made** (`hubAgain`) lets only this Mac's own key
    /// in, as root, on the private network: its install starts again as its build started it, with no check page.
    private func useExisting(_ server: CloudExisting) {
        guard !pressRepeats else { return }
        if case .install(let onNetwork)? = hubAgain(server), let provider = cloud.provider {
            work.chosenServer = (provider, server.id, onNetwork)
            cloud.cancel()
            work.hubBuilt = false
            startInstall(InstallTarget(host: onNetwork, user: "root", port: 22, identityFile: AppSSHKey.path()))
            return
        }
        // A row that only the rule above made usable, and that the network's next reading no longer shows, is not a
        // server to check: the check goes to the public address, where a server that the app made has no way in.
        guard server.unfit(for: .hub, fleet: []) == nil, let address = server.ipv4 else { return }
        work.chosenServer = cloud.provider.map { ($0, server.id, address) }
        cloud.cancel(); vps.reset()
        vps.addressText = address; vps.tailnet = model.mac?.tailnet
        model.start(.vps)
        vps.check(job: .hub)
    }

    private func startInstall(_ target: InstallTarget, sudo: PasswordOnce.Password? = nil) {
        // A refusal of the manager's server of an earlier try holds nothing of this one.
        model.managersRefusal = nil
        model.managersFull = []
        model.managersMoreShown = false
        install.use(target, sudo: sudo)
        // The install keeps the name for its Try again, which runs the same install.
        install.managerName = model.hubName
        install.oneServer = model.oneServer
        install.shape = model.shaped ? model.serversStep : nil
        install.runtime = model.chosenAI
        // The account's server that "Use this server" chose, when the install goes to its address.
        install.provenServer = work.chosenServer.flatMap { $0.address == target.host ? ($0.provider, $0.id) : nil }
        // A join of the manager's server of an earlier try went to that try's hub.
        if !managerInstall.running { managerInstall.again() }
        install.installHub(store: store)
        model.start(.installing)
        // The window holds for the wizard also when the build's end starts the install while another page has the
        // window (`FirstRunWork`): no `onChange` of the wizard runs then, and the hub's claim would take it to the app.
        // Not for a first run that is over, nor over a fleet that answers this Mac (connected from Settings meanwhile).
        if store.state == nil, FirstRunWork.isKept(work) { hold(model.holdsWindow) }
    }

    /// **One press makes every server of the fleet** (slice 2 of the one wizard): the hub's server, whose install
    /// starts as soon as it is on the private network, and on 2 servers and 1 per agent the manager's own server, made
    /// from that moment on (`makeManagersServer`).
    private func makeFleet() {
        let managers = model.makesManagersServer
        model.managersRefusal = nil
        model.managersFull = []
        model.managersMoreShown = false
        cloud.makeNew { target in
            work.hubBuilt = true
            startInstall(target)
            if managers { makeManagersServer(hubOnNetwork: target.host) }
        }
    }

    /// **The manager's own server, made under the hood once the hub's server is on the private network**: its name is
    /// then not the hub's (`FleetOnTailscale.freeName` reads that network), and its build record and the provider's
    /// note of it are kept for the hub's address that the claim gives (`StartAgain.hubAddress`), as the hub's own build
    /// keeps its server. The manager's setup then installs it by itself (`FleetStore.madeServer`, `AddServerView`),
    /// with no VPS page and no second server. A build that stops leaves that setup its own pages, where the provider's
    /// list offers the server that this build made (`MadeServers`). A second try of the hub's server in this run takes
    /// the manager's server of the first try again, for the new hub's address, and makes no other.
    private func makeManagersServer(hubOnNetwork host: String) {
        guard let future = StartAgain.hubAddress(onNetwork: host) else { return }
        makeManagersServer(for: future)
    }

    private func makeManagersServer(for future: URL) {
        model.managersHub = future
        if model.managersServer != nil {
            keepManagersServer(for: future)
            noteManagersServer()
            return
        }
        // A build of it that still runs refuses this one, and its end keeps its server for this address.
        guard let provider = managerCloud.provider else { return }
        managerCloud.makeNew(for: future, made: { name, id in
            model.managersServerMade = (name, id, provider)
            MadeServers.note(name, id: id, hub: future)
        }) { target in
            guard let made = model.managersServerMade else { return }
            model.managersServer = FleetStore.MadeServer(name: made.name, address: target.host)
            // A newer try of the hub's server came while this build ran: the server is that hub's now.
            if let newest = model.managersHub, newest != future { keepManagersServer(for: newest) }
            noteManagersServer()
        }
    }

    /// The manager's own server of this run, kept for another try's hub address: its note at the provider's list, and
    /// its build record, by its id.
    private func keepManagersServer(for hub: URL) {
        guard let made = model.managersServerMade else { return }
        MadeServers.note(made.name, id: made.id, hub: hub)
        if let id = made.id { BuildRecords.shared.noteJoined(serverID: id, provider: made.provider, hub: hub.absoluteString) }
    }

    /// **The manager's own server goes to its setup** (`FleetStore.noteMadeServer`) once the hub has a manager with no
    /// server: at the hand-over, or as the server comes on the private network after it.
    private func noteManagersServer() {
        guard let server = model.managersServer,
              let manager = store.state?.agents.first(where: { $0.role == "manager" && !$0.placed })?.name else { return }
        // Kept for the hub that it goes to, this one: also when another try of the hub's server made it, or when a
        // later try took the account's list, whose press makes the hub's server alone.
        keepManagersServer(for: store.hub)
        store.noteMadeServer(server, for: manager)
    }

    /// **The manager's own server's offer opens with the hub's**, on 2 servers and 1 per agent: at the hub's provider,
    /// or at the one that the owner chose for it (`managersProvider`, slice 2b), once this Mac holds that provider's
    /// token. A build of that server that runs is never touched.
    private func opensManagersChoice() {
        guard model.makesManagersServer, case .token(let hubs) = model.step, cloud.stage == .choosing,
              cloud.tokenTaken else { return }
        let provider = model.managersProvider ?? hubs
        switch managerCloud.stage {
        case .token:
            if managerCloud.holds(provider) { managerCloud.open(provider, use: .agent, lists: false) }
        case .choosing where managerCloud.provider != provider:
            managerCloud.cancel()
            if managerCloud.holds(provider) { managerCloud.open(provider, use: .agent, lists: false) }
        case .choosing, .making, .joining:
            break
        }
    }

    /// **The hub's server at another provider** (its capsule's "Another provider", slice 2b): that provider's step,
    /// which opens its choice when this Mac holds its token and asks for the token first when not. The manager's own
    /// server that goes with the hub's provider goes there too (`opensManagersChoice`).
    private func hubAt(_ provider: CloudProvider) {
        // The manager's own provider that is the hub's new one goes with the hub's, as one choice of it does.
        if model.managersProvider == provider { model.managersProvider = nil }
        cloud.cancel()
        // The manager's server that goes with the hub's goes there; one at that provider already keeps its type.
        if model.managersProvider == nil, managerCloud.stage == .choosing, managerCloud.provider != provider {
            managerCloud.cancel()
        }
        model.choose(.token(provider))
        opensChoice()
        // A provider whose token this Mac holds opens in this same call, so no `onChange` of the hub's model sees it.
        opensManagersChoice()
    }

    /// **The manager's own server at another provider** (its capsule's "Another provider", slice 2b): its choice opens
    /// there when this Mac holds that provider's token, and that provider's token page shows first when not. The hub's
    /// own provider again is the hub's provider again.
    private func managersAt(_ provider: CloudProvider) {
        guard let hubs = cloud.provider, managerCloud.stage == .token || managerCloud.stage == .choosing else { return }
        model.managersProvider = provider == hubs ? nil : provider
        managerCloud.cancel()
        if managerCloud.holds(provider) {
            managerCloud.open(provider, use: .agent, lists: false)
        } else {
            model.managersToken = provider
        }
    }

    // MARK: the build page (slice 3 of the one wizard)

    private static let hubPlan = InstallPlan.hub(target: InstallTarget(host: "server"), source: "", authKey: nil).steps.map(\.id)
    private static let joinPlan = InstallPlan.join(target: InstallTarget(host: "server"), line: "", code: "", authKey: nil)
        .steps.map(\.id)

    /// **The build page shows the install** while the fleet builds with nothing for the owner to do or read (the
    /// owner's "that is brilliant!" of 16 November 2026 to its picture): the hub's install, and the manager's join after
    /// the hub's own end. A stop of the hub's install, Tailscale's own link, a key that the network asks for, and the
    /// end show the install's own page, as before. A first run that did not come through the slider's page keeps it.
    private var showsBuild: Bool {
        guard model.shaped, model.step == .installing else { return false }
        let clear = install.failure == nil && !install.needsNetworkKey && install.networkSignIn == nil
        return clear && (install.running || (managerInstall.running || managersHolds) && install.checklist != nil)
    }

    // MARK: a refused server on the build page (slice 3, the picture's third element)

    /// The manager's own server was refused, and its choice shows: its words, its capsule and its press.
    private var managersChoiceOpen: Bool {
        guard model.makesManagersServer, model.managersServer == nil,
              model.managersRefusal != nil || managersRefusedNow else { return false }
        // Its choice shows, is read now, or its provider's token page shows. A read that failed too leaves the server to
        // the manager's setup, as before slice 3: the first run does not wait for a choice that cannot show.
        return managerCloud.offer != nil || model.managersToken != nil || managersTokenRefusedNow
            || (managerCloud.stage == .choosing && managerCloud.stopped != .choosing)
    }

    /// The manager's own provider refused the token that this Mac holds for it, before its `onChange` showed the token
    /// page (`managersToken`): the first run's end reads it directly, as it reads a refusal (`managersRefusedNow`).
    private var managersTokenRefusedNow: Bool {
        guard let own = model.managersProvider else { return false }
        return managerCloud.provider == own && managerCloud.stopped == .token && !managerCloud.tokenTaken
    }

    /// **A build of the manager's own server stopped, and its model read the choice again**: the model does that only
    /// when nothing is left at the provider (`CloudStop.readsListAgain`: taken, no room, a full account, a wait). Every
    /// other stop (no answer, a refusal in the provider's words, a server left behind) keeps the line alone, and no
    /// press here may make a second server.
    private var managersRefusedNow: Bool {
        model.step == .installing && model.makesManagersServer && model.managersServer == nil
            && model.managersServerMade?.id == nil && managerCloud.stopped == .making && managerCloud.stage == .choosing
    }

    /// The manager's own server is made now, by its provider.
    private var managersBuilds: Bool { managerCloud.stage == .making || managerCloud.stage == .joining }

    /// **The first run waits for the manager's own server**: while its choice is open, the owner's turn, and while the
    /// press's build runs. Its end then hands over with that server (`finish`), as when nothing was refused.
    private var managersHolds: Bool { managersBuilds || managersChoiceOpen && !managersStuck }

    /// **A choice that cannot lead on by itself**: its capsule stands at a provider that answered "no room in your
    /// account", and no token page of another one shows. The page keeps it while the hub installs; after the hub's end
    /// the first run goes on, and the manager's setup asks for the server, as before slice 3. It never waits for good.
    private var managersStuck: Bool {
        guard model.managersToken == nil, let provider = managerCloud.provider else { return false }
        return model.managersFull.contains(provider)
    }

    /// The title moves while something builds; with only the owner's choice left it stands.
    private var buildWaits: Bool { install.running || managerInstall.running || managersBuilds || !managersChoiceOpen }

    /// **A refusal of the manager's own server on the build page** (the owner, 17 November 2026: "it sohuld never
    /// happen! hetzner has alternatives even if more expensive, we need to show more options!"): its words stay over its
    /// capsule. An account with no room reads no other type of its provider: another provider whose token this Mac
    /// holds opens at once. A stop that reads no choice again opens it, at the same provider.
    private func managersRefused(_ stop: FleetCloudModel.Stage?) {
        // A build's stop that the model read again only: a token that the next provider refused keeps the refusal's
        // own words, and a stop that the model holds (`managersRefusedNow`) opens no choice.
        guard stop == .making, managersRefusedNow, let words = managerCloud.failure, let provider = managerCloud.provider
        else { return }
        model.managersRefusal = words
        if managerCloud.accountFull { model.managersFull.insert(provider) }
        if managerCloud.accountFull,
           let other = CloudProvider.allCases.first(where: {
               !model.managersFull.contains($0) && CloudServers(provider: $0).isHeld
           }) {
            managersAt(other)
        }
    }

    /// The manager's capsule on the build page, with the refusal's words over it and its press under it.
    private var managersChoice: ServerBoxChoice? {
        let name = ManagerName.shown(model.managerName)
        let held = Set(CloudProvider.allCases.filter { CloudServers(provider: $0).isHeld })
        guard var choice = ServerBoxChoice.of(managerCloud, title: String(l10n: "\(name)'s server"), held: held,
                                              elsewhere: managersAt) else { return nil }
        choice.why = model.managersRefusal ?? managerCloud.failure
        let press = String(l10n: "Make \(name)'s server")
        choice.press = (press, { makeManagersServerAgain() })
        // **Hetzner's account had no room** (`CloudError.full`): its own way to more servers, under the line (Hetzner's
        // console: the account's Limits tab, Request change, Limit increase; answered by hand, from an account's second
        // month on). Each server takes two of the account's primary IPs, an IPv4 and an IPv6.
        // Only under Hetzner's own line: a later refusal of another provider has its own words.
        if model.managersFull.contains(.hetzner), choice.why == CloudError.full(.hetzner).errorDescription {
            let hetzner = CloudProvider.hetzner.name
            choice.more = .init(
                link: String(l10n: "How to get more servers at \(hetzner)"),
                // The Limits tab is the account's, beside Projects: Hetzner counts its limits across all projects.
                steps: [String(l10n: "Open [Hetzner Console](\(FleetCloudModel.tokenPage(.hetzner).absoluteString))"),
                        String(l10n: "Limits › Request change › Limit increase"),
                        // Hetzner answers by hand, often after the first run handed over: the press is then the setup's.
                        String(l10n: "When \(hetzner) says yes, make the server again")],
                note: String(l10n: "Hetzner answers by hand, in its business hours. An account younger than a month cannot ask yet."),
                shown: model.managersMoreShown, show: { model.managersMoreShown = true })
        }
        return choice
    }

    /// **The press "Make <name>'s server"**: the manager's own server of the capsule, for the hub's address of this run.
    private func makeManagersServerAgain() {
        guard let future = model.managersHub, managerCloud.stage == .choosing else { return }
        model.managersRefusal = nil
        makeManagersServer(for: future)
    }

    /// The line of each box of `ServerBoxes`, by its place: the hub's server first, then the manager's own.
    private var buildRows: [FleetBuildRow?] { model.makesManagersServer ? [hubRow, managersRow] : [hubRow] }

    private var hubRow: FleetBuildRow? {
        if cloudBuilds { return .building(joining: cloud.stage == .joining, plan: Self.hubPlan) }
        if install.checklist != nil { return .ready }
        if let phases = InstallPhases(steps: install.steps, planned: install.planned,
                                      runningFor: Date().timeIntervalSince(install.runningSince))
            .map(install.hold.applied(to:)) {
            return .installing(phases, afterBuild: work.hubBuilt)
        }
        return .starting(plan: Self.hubPlan, afterBuild: work.hubBuilt)
    }

    /// The manager's own server: its build, its wait for the hub, its join; none before its build begins, nor after a
    /// join that stopped, whose server its setup installs again.
    private var managersRow: FleetBuildRow? {
        guard model.makesManagersServer, !managersChoiceOpen else { return nil }
        if managerInstall.checklist != nil { return .ready }
        if managerInstall.running {
            return InstallPhases(steps: managerInstall.steps, planned: managerInstall.planned,
                                 runningFor: Date().timeIntervalSince(managerInstall.runningSince))
                .map(managerInstall.hold.applied(to:))
                .map { .installing($0, joinFor: ManagerName.shown(model.managerName), afterBuild: true) }
                ?? .starting(plan: Self.joinPlan, afterBuild: true)
        }
        if managerInstall.failure != nil { return nil }
        switch managerCloud.stage {
        case .making: return .building(joining: false, plan: Self.joinPlan)
        case .joining: return .building(joining: true, plan: Self.joinPlan)
        case .token, .choosing: return model.managersServer != nil ? .waitsForHub(plan: Self.joinPlan) : nil
        }
    }

    /// **The build page** (`FleetBuildPage`): every server of the fleet with its line under the moving title, its
    /// minutes read again every 20 seconds, as the install's own page reads them.
    private var buildPage: some View {
        TimelineView(.periodic(from: .now, by: 20)) { _ in
            FleetBuildPage(title: String(l10n: "Building your fleet"), waits: buildWaits,
                           plan: FleetPlan(manager: model.managerName, agents: []), step: model.serversStep,
                           rows: buildRows, choices: managersChoiceOpen ? [nil, managersChoice] : []) { mark } below: {
                EmptyView()
            }
        }
    }

    /// **The manager's join starts once the hub has claimed itself** (`MachineInstallModel.claimedHubURL`): when the
    /// new hub answers there and the manager's own server is on the private network, the join goes to that hub
    /// (`installMachine(store:at:)`), while the hub's own install ends (the proof of 16 November 2026). A count of reads
    /// ends the wait (no clock ends work), and so does a stop of the hub's install; the manager's setup then installs
    /// the server, as before.
    private func startManagersJoin() async {
        guard model.makesManagersServer, let hub = install.claimedHubURL else { return }
        for read in 0..<60 {
            if read > 0 { try? await Task.sleep(for: .seconds(10)) }
            guard !Task.isCancelled, install.failure == nil, !managerInstall.running, managerInstall.checklist == nil,
                  managerInstall.failure == nil else { return }
            guard let server = model.managersServer, let state = try? await HubClient().state(at: hub) else { continue }
            guard !Task.isCancelled, !managerInstall.running, !work.handedOver, model.step == .installing else { return }
            managerInstall.use(InstallTarget(host: server.address, user: "root", port: 22, identityFile: AppSSHKey.path()))
            managerInstall.installMachine(store: store, at: .init(url: hub, database: state.db,
                                                                  asksName: Servers.asksName(state.ui_features)))
            return
        }
    }

    /// The steps and the field of the manager's own provider's token (`managersToken`), on "Your fleet"'s step and on the
    /// build page alike.
    @ViewBuilder private func managersTokenFields(_ other: CloudProvider) -> some View {
        SetupSteps.token(other)
        PasteField(placeholder: String(l10n: "Paste it here"), text: $managerCloud.tokenText,
                   accepts: { $0.count >= 20 && !$0.contains(" ") }) {
            managerCloud.sendToken(other, use: .agent, lists: false)
        }
        .accessibilityIdentifier("first-run-managers-token")
    }

    private func token(_ provider: CloudProvider) -> some View {
        let building = cloudBuilds
        let choosing = cloud.stage == .choosing
        let head = tokenHead(provider)
        // The page "Your fleet" draws the slider page's boxes, with a capsule under each server (`fleetWidth`).
        let width = choosing && showsFleet && model.managersToken == nil ? ShapeMetrics.fleetWidth : SetupMetrics.width
        return SetupStep(title: head.title, waits: head.waits, width: width) {
            // The provider's own logo over its pages, as Add server has it (the owner, 10 November 2026).
            CloudMark(provider: model.managersToken ?? provider, size: SetupMetrics.mark)
        } content: {
            if building {
                CloudBuilding(stage: cloud.stage, provider: cloud.provider)
            } else if let other = model.managersToken {
                // **The token of the manager's own provider** (slice 2b): its page, as the hub's provider's, for the
                // manager's model; once the provider took it, "Your fleet" again.
                managersTokenFields(other)
            } else if choosing, showsFleet {
                FirstFleetChoice(cloud: cloud, managers: model.makesManagersServer ? managerCloud : nil,
                                 plan: FleetPlan(manager: model.managerName, agents: []), step: model.serversStep,
                                 hubAt: hubAt, managersAt: managersAt, make: makeFleet)
            } else if choosing {
                // Read here, in the page's own body, so that each row follows the page's readings.
                let again = Dictionary(cloud.existing.map { ($0.id, hubAgain($0)) }) { first, _ in first }
                CloudChoice(cloud: cloud, job: .hub, fleet: [], reuse: { again[$0.id] ?? nil },
                            reuseWords: Self.madeForHub, makeNew: makeHub, use: useExisting)
            } else if !cloud.tokenTaken {
                // A token that the provider took is never asked for again on this page (`FleetCloudModel.tokenTaken`).
                SetupSteps.token(provider)
                PasteField(placeholder: String(l10n: "Paste it here"), text: $cloud.tokenText,
                           accepts: { $0.count >= 20 && !$0.contains(" ") }) {
                    cloud.sendToken(provider, use: .hub)
                }
                .accessibilityIdentifier("first-run-cloud-token")
            }
            if model.managersToken != nil {
                if let failure = managerCloud.failure { SetupWarning(failure) }
            } else {
                // While the list shows, its own press carries the line (`CloudChoice`).
                if let failure = cloud.failure, !choosing || cloud.offer == nil { SetupWarning(failure) }
                // The offer of the manager's own server that could not be read: it is read again by itself.
                if choosing, showsFleet, model.makesManagersServer, managerCloud.offer == nil,
                   let failure = managerCloud.failure, failure != cloud.failure {
                    SetupWarning(failure)
                }
            }
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
                Button("Install") {
                    if let target = vps.target { work.hubBuilt = false; startInstall(target, sudo: vps.sudoPassword) }
                }
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
            // while this Mac connects to the hub it claimed, the title says that in moving words, never "Installing your
            // hub" again, until the wizard goes on by itself.
            let checked = !install.running && install.checklist != nil
            // The title and its moving words: `machineHead`. **The build page** while the fleet builds with nothing
            // for the owner to do or read (`showsBuild`); the install's own page for a stop, a link, a key and the end.
            Group {
                if showsBuild, let other = model.managersToken {
                    SetupStep(title: machineHead.title, waits: machineHead.waits) {
                        CloudMark(provider: other, size: SetupMetrics.mark)
                    } content: {
                        managersTokenFields(other)
                        if let failure = managerCloud.failure { SetupWarning(failure) }
                    }
                } else if showsBuild {
                    buildPage
                } else {
                    SetupStep(title: machineHead.title, waits: machineHead.waits) { mark } content: {
                        form {
                            MachineInstallRun(model: install, title: String(l10n: "Your hub"), next: AnyView(afterInstall),
                                              again: { install.installHub(store: store) }, report: { store.reportAsk = $0 })
                        }
                    }
                }
            }
            // **On to Manager's sign-in by itself** (D-3 item 1, his rule "it should just activate it"; fix round 2): when
            // the hub answers and its checks passed, as the done step goes on. **A failed check stops it** (review A6):
            // its checks stand under "Your hub is installed", with Open Founderizer, as in 0.1.68. The manager's join
            // from this run ends first (slice 3), so that no second install of its server begins.
            .onChange(of: checked && passed && store.state != nil && !managerInstall.running && !managersHolds,
                      initial: true) { _, onwards in
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
    /// Until the hub's first reading, the step's title says "Connecting to your hub" in moving words. Then, after a
    /// failed check, Open Founderizer under the checks; else the wizard goes on by itself (`machine`).
    @ViewBuilder private var afterInstall: some View {
        if store.state != nil && !passed {
            VStack(spacing: FleetSpace.inside) {
                Button("Open Founderizer") { openApp() }
                    .buttonStyle(FleetPrimaryButtonStyle()).accessibilityIdentifier("first-run-open")
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
    /// "it should just activate it"): no Open Founderizer to press, no sentence of what comes next, and no question of a
    /// copy (the owner, 18 November 2026: "Take it away"; a copy goes back from Settings › Backup).
    private var done: some View {
        // The title and its moving words: `doneHead`.
        return SetupStep(title: doneHead.title, waits: doneHead.waits) { mark } content: {
            form { proofs }
        }
        .onChange(of: allProved && !managersHolds, initial: true) { _, onwards in if onwards { finish() } }
    }

    /// **A check shows only while it has not passed** (D-2): three "Yes" rows that said the hub answers, that this Mac
    /// owns it and that the fleet reads stood on every first run; a check that did not pass keeps its row.
    private var proofs: some View {
        Group {
            FormSection {
                if !model.reached { proof(String(l10n: "Your hub answers"), false, String(l10n: "This Mac reached it on your private network.")) }
                if !model.owned { proof(String(l10n: "This Mac is its owner"), false, String(l10n: "Your hub serves its pages to this Mac and to nothing else.")) }
                if store.state == nil { proof(String(l10n: "Your fleet is reading"), false, String(l10n: "Waiting for the first read.")) }
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
