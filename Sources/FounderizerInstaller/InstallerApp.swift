import AppKit
import Darwin
import FleetCore
import FleetMark
import Observation
import SwiftUI

/// The Founderizer installer for **a Mac that stays on** (PRODUCT.md 2 and P3).
///
/// The customer downloads it, opens it on the Mac mini or Mac Studio that will run their agents, and types the one
/// link code it shows into Founderizer on their own Mac. Their app then sends the order — their hub's address, the
/// one-time join line, the first agent's name and, when this Mac is not on their private network yet, their Tailscale
/// key — and from there this installer leads one sitting at this Mac (`MacSittingPage`), to the last press.
///
/// A bare Mac needs nothing first: macOS's own password dialog opens one root step (`Installer/setup.sh`), which
/// installs the rest. The password never reaches this app, the link code is the whole authorization of the order, and
/// three wrong codes stop the listener.
@main
struct FounderizerInstallerApp: App {
    @State private var model = InstallerModel()

    var body: some Scene {
        WindowGroup("Founderizer installer") {
            InstallerView(model: model)
                .frame(minWidth: model.page.isSmallWindow ? InstallerModel.smallWidth : 520,
                       minHeight: model.page.isSmallWindow ? InstallerModel.smallHeight : 440)
                .task { model.begin() }
        }
        .windowResizability(.contentMinSize)
    }
}

@MainActor @Observable
final class InstallerModel {
    private(set) var code = ""
    private(set) var port = UInt16(MacInstallerClient.port)
    private(set) var addresses: [String] = []
    private(set) var page = MacSittingPage.link
    /// The one word over the bar while the root step runs: nil before its first word.
    private(set) var word: String?
    /// What stopped the page, in the owner's words. Try again goes on from there.
    private(set) var failure: String?
    private(set) var laptop = false
    /// The owner came to this page with Back: it waits for him, with a Next, and opens nothing by itself.
    private(set) var cameBack = false
    /// The last press is on its way to the hub: no Back and no second press.
    private(set) var finishing = false
    /// This Mac is at it, and the owner has nothing to do: a spinner takes the button's place, as on the setup page.
    private(set) var working = false
    /// A later opening leads only what is missing: the pages left, nil in a first sitting.
    private(set) var missing: [MacSittingPage]?
    /// The AI that this Mac runs without: the buttons of "Nothing is missing".
    private(set) var addable: [ServerAI] = []
    /// A later opening's reading has just asked for a screenshot, so the page does not ask a second time.
    @ObservationIgnored private var screenAsked = false
    /// What the hub says that this Mac needs, and the AI that the owner adds at this opening.
    @ObservationIgnored private var needs: MacNeeds?
    @ObservationIgnored private var plan = MacSittingPlan.both
    @ObservationIgnored private var adding: Set<ServerAI> = []
    @ObservationIgnored private var placed = false
    @ObservationIgnored private var opening = false
    /// Chrome has had its one start for the extension: it fetches the extension from there.
    @ObservationIgnored private var chromeStarted = false
    /// Once Claude Code is signed in or the proof has failed, the extension here is what the button goes to.
    @ObservationIgnored private var toExtension = false
    @ObservationIgnored private var state = MacInstallState(state: "waiting", says: "Waiting for your app.")
    @ObservationIgnored private var listener: MacInstallerListener?
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var order: MacInstallOrder?
    private(set) var fileVault = false
    @ObservationIgnored private var run = ""
    @ObservationIgnored private var signingIn = false
    @ObservationIgnored private var reconnected = false
    @ObservationIgnored private var tries = 0

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    /// The root step's input. Only this Mac's user can open it.
    private static let work = home.appendingPathComponent(".founderizer-setup")
    /// What the root step writes: its one word, its log and its end. Only root can write here.
    private static let state = URL(fileURLWithPath: "/var/run/founderizer-setup")
    private static let record = home.appendingPathComponent(".fleet/sitting.json")
    private static let loginItem = home.appendingPathComponent("Library/LaunchAgents/com.founderizer.installer.plist")
    private static let installed = "/Applications/Founderizer Installer.app"
    private static let restartMark = "/Users/Shared/.founderizer-restart"
    private static let chatGPT = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
    /// By path: macOS's list of app names can take minutes to learn an app that has just arrived.
    private static let chromeApp = "/Applications/Google Chrome.app"
    private static let chatGPTApp = "/Applications/ChatGPT.app"
    private static let systemSettingsApp = "/System/Applications/System Settings.app"
    static let smallWidth: CGFloat = 340, smallHeight: CGFloat = 360
    private static let reconnect = "https://clau.de/chrome/reconnect"
    private static let extensionPage = "chrome://extensions/?id=fcoeoabgfenejglbffodgkkbkcdhcgfn"
    private static let extensionStore = "https://chromewebstore.google.com/detail/claude/fcoeoabgfenejglbffodgkkbkcdhcgfn"
    /// The extension's own page: one Log in button while it is signed out, which always starts a sign-in of its own.
    private static let extensionLogin = "chrome-extension://fcoeoabgfenejglbffodgkkbkcdhcgfn/options.html"
    /// The last address that the runtime's own sign-in opened in Chrome: the button opens it again.
    private static let signInAddress = work.appendingPathComponent("sign-in-address")
    private static let extensionSignInQuery = "select url from urls where url like 'https://claude.ai/oauth/authorize?%' "
        + "and url like '%fcoeoabgfenejglbffodgkkbkcdhcgfn%' order by last_visit_time desc limit 1"
    /// The real browser task of the sitting: Claude Code in Chrome, with the owner there for what Chrome may ask.
    private static func proof(_ address: URL) -> String {
        "Open \(address.absoluteString) in Chrome with your browser tools, and wait until the page says Done. Use no other tool."
    }
    /// The sentence of macOS's own password dialog: what this Mac becomes, said once.
    private static let prompt = "This Mac stays signed in. Anyone who touches it acts as your agents."
    /// Looks at the Mac for its runtime, two seconds apart, before the page says that it did not come.
    private static let claudeWaits = 300
    /// Looks at a signed-in Mac for a Codex agent's own copy, three seconds apart.
    private static let codexWaits = 200
    /// Readings with Claude Code signed in and no browser, before the page says so: an extension on another account
    /// never answers, and nothing else would tell the owner.
    private static let browserWaits = 70
    private static let noAnswer = "This Mac's Chrome did not open the test page. Check that Claude's extension is logged in "
        + "here, with the account made for this Mac."
    private static let noScreen = "Computer Use cannot see this Mac's screen yet."
    /// The calls on arrival at Computer Use while OpenAI's window has not come.
    private static let windowCalls = 3
    private static let noHub = "Your hub did not answer. Try again."
    private static let vault = home.appendingPathComponent("Library/Application Support/AgentFleet/vault.sock")

    /// Where the agent's install puts it, or where its owner has it from before.
    private var claude: String {
        let own = Self.home.appendingPathComponent(".local/bin/claude").path
        return [own, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? own
    }
    /// The Codex agent's own copy, which its install job brings, beside the one in the ChatGPT app.
    private var agentCodex: String {
        let own = Self.home.appendingPathComponent(".local/bin/codex").path
        return [own, "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? own
    }
    private var user: String { NSUserName() }

    /// Back stands in a first sitting: a later opening shows only what is missing, and goes on by itself.
    var canGoBack: Bool { !finishing && missing == nil && page.previous(fileVault: fileVault, plan: plan) != nil }

    /// The page's logo: the app's own icon on this Mac. Claude Code has no app here, so Founderizer carries its logo.
    var logo: Image? {
        switch page.logo {
        case .claude: ProviderLogo.image("claude")
        case .systemSettings: Self.icon(Self.systemSettingsApp)
        case .chrome: Self.icon(Self.chromeApp)
        case .chatGPT: Self.icon(Self.chatGPTApp)
        case nil: nil
        }
    }

    private static func icon(_ app: String) -> Image { Image(nsImage: NSWorkspace.shared.icon(forFile: app)) }

    /// Comes back to the page of a sitting that a power cut stopped. Else: makes the link code and waits for the
    /// owner's own app.
    func begin() {
        guard listener == nil else { return }
        NSApplication.shared.disableRelaunchOnLogin()       // macOS would bring it back after Finish's restart
        guard moveToApplications() else { return }
        laptop = InstallerModel.modelName().localizedCaseInsensitiveContains("book")
        code = (0..<12).map { _ in String(ClaimCode.alphabet.randomElement() ?? "A") }.joined()
        addresses = InstallerModel.ownAddresses()
        state = MacInstallState(state: "waiting", says: "Waiting for your app.")
        let listener = MacInstallerListener(code: code, state: state) { [weak self] order in
            Task { @MainActor in self?.take(order) }
        }
        do { port = try listener.start() } catch {
            failure = "This Mac could not listen on port \(MacInstallerClient.port): \(error.localizedDescription)"
            return
        }
        self.listener = listener
        resume()
    }

    /// The sitting a quit or a power cut left: the root step, which goes on by itself, or the page it stood on. A Mac
    /// that has left its fleet has no sitting any more.
    private func resume() {
        for name in ["line", "authkey"] where !rootStepRuns {
            try? FileManager.default.removeItem(at: Self.work.appendingPathComponent(name))
        }
        let kept = MacSittingRecord.read(Self.record)
        if let kept, kept.page == .setup, let run = kept.run, rootStepRuns || file("exit").flatMap({
            MacSittingRead.status($0, run: run) }) != nil {
            self.run = run
            page = .setup
            return watchRootStep()
        }
        guard joinedBefore else { return }
        if kept?.page == .setup { return startRootStep() }  // a power cut in its last part: it goes on, with no order
        Task {
            await readFileVault()
            guard page == .link else { return }             // an order came meanwhile
            await goOn(from: kept?.page)
        }
    }

    /// A start on a Mac that has joined. The hub says whether a sitting runs, never a file here: a page on the disk can
    /// be what a later opening left.
    private func goOn(from kept: MacSittingPage?) async {
        let reading = await readNeeds()
        guard order == nil else { return }                  // an order came meanwhile
        switch reading {
        case .left: break                                   // the link code stands: this Mac left its fleet
        case .older:
            if let kept, kept != .link { show(kept) }       // a hub from before the choice: as it was, with both
        case .unread:
            if let kept, kept != .link { page = .checking } // else the link code stands under the line, for a new hub
            failure = Self.noHub
        case .needs(let needs):
            self.needs = needs
            plan = needs.plan
            guard needs.inSitting else { return show(.checking) }
            let pages = plan.pages(fileVault: fileVault)
            show(kept.flatMap { pages.contains($0) ? $0 : nil } ?? MacSittingPage.setup.next(fileVault: fileVault, plan: plan) ?? .finish)
        }
    }

    private func readNeeds() async -> MacNeeds.Reading {
        MacNeeds.read((try? await LocalShell.sh("python3 \"$HOME/fleet-server/server.py\" needs", timeout: 40))?.output ?? "")
    }

    private var joinedBefore: Bool {
        FileManager.default.fileExists(atPath: Self.home.appendingPathComponent(".fleet/server.json").path)
    }

    /// The root step's process is alive: a process of root answers "not permitted", and a dead one "no such process".
    private var rootStepRuns: Bool {
        guard let pid = file("pid").flatMap({ pid_t($0) }) else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: The way into the sitting

    /// The download stands on a disk image that goes away. The login item needs a place that stays, so the installer
    /// copies itself once, and goes on from the copy. The copy is the app the owner just opened: no second question.
    private func moveToApplications() -> Bool {
        let here = Bundle.main.bundlePath, manager = FileManager.default
        guard here != Self.installed else { return true }
        try? manager.removeItem(atPath: Self.installed)
        guard !manager.fileExists(atPath: Self.installed), (try? manager.copyItem(atPath: here, toPath: Self.installed)) != nil else {
            return true         // this user cannot write there: the installer goes on from where it stands
        }
        Task {
            _ = try? await LocalShell.run("/usr/bin/xattr", ["-cr", Self.installed])
            _ = try? await LocalShell.run("/usr/bin/open", ["-n", Self.installed])
            NSApplication.shared.terminate(nil)
        }
        return false
    }

    /// A power cut in the sitting must not lose the owner's place: this agent opens the installer at login, until
    /// Finish takes it away.
    private func addLoginItem() {
        let plist: [String: Any] = ["Label": "com.founderizer.installer", "RunAtLoad": true,
                                    "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath]]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? FileManager.default.createDirectory(at: Self.loginItem.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.loginItem, options: .atomic)
    }

    private func take(_ order: MacInstallOrder) {
        guard !rootStepRuns else { return }     // the app's Try again: this Mac is at it already, and says so at /state
        self.order = order
        addLoginItem()
        Task {
            if order.authKey == nil, !(await InstallerModel.onTheNetwork()) {
                return stop("This Mac is not on your private network.")     // the app's answer is a key, in a new order
            }
            startRootStep()
        }
    }

    /// Everything that needs root, in one step behind macOS's own dialog. It goes on by itself once it has started,
    /// so a quit of this app does not stop it, and the app reads how it stands from its folder.
    private func startRootStep() {
        guard order != nil || joinedBefore, let script = Bundle.main.path(forResource: "setup", ofType: "sh") else {
            return stop("This installer has no setup step. Download it again.")
        }
        failure = nil
        word = nil
        run = UUID().uuidString
        show(.setup)
        state = MacInstallState(state: "running", says: "Setting up this Mac")
        listener?.workAgain(state)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: Self.work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.work.path)
            try? manager.removeItem(at: Self.work.appendingPathComponent("authkey"))
            if let order {
                try secret(order.line + "\n", "line")
                if let key = order.authKey { try secret(key + "\n", "authkey") }
            }
        } catch { return stop("This Mac could not save the order: \(error.localizedDescription)") }
        // In a moment, so that the page shows behind macOS's dialog: the dialog holds the main thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            // Not nohup: as root behind this dialog it stops at once, with its one line of why in /dev/null.
            let command = "/bin/sh " + InstallerModel.quoted(script) + " " + InstallerModel.quoted(Self.work.path) + " "
                + self.run + " >/dev/null 2>&1 </dev/null &"
            guard InstallerModel.asAdministrator(command, prompt: Self.prompt) else {
                for name in ["line", "authkey"] { try? manager.removeItem(at: Self.work.appendingPathComponent(name)) }
                return self.stop("This Mac needs your password to go on.")
            }
            self.watchRootStep()
        }
    }

    private func secret(_ text: String, _ name: String) throws {
        let file = Self.work.appendingPathComponent(name)
        try Data(text.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func watchRootStep() {
        watching { model in
            var gone = 0
            while !Task.isCancelled {
                if let said = model.file("word") { model.word = said }
                if let status = model.file("exit").flatMap({ MacSittingRead.status($0, run: model.run) }) {
                    guard status == 0 else { return model.stop(MacSittingRead.stopped(model.file("log") ?? "")) }
                    model.word = ""         // every part has ended, also when the step's last word came after this read
                    return await model.joined()
                }
                // A step that a kill ended writes no end. Some seconds pass before a new one has written its number.
                gone = model.rootStepRuns ? 0 : gone + 1
                if gone >= 15 { return model.stop(MacSittingRead.stopped(model.file("log") ?? "")) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func file(_ name: String) -> String? {
        (try? String(contentsOf: Self.state.appendingPathComponent(name), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Mac has joined: the owner's own app can stop waiting, and the pages that need a person begin.
    private func joined() async {
        await readFileVault()
        order = nil
        Task { await reportChecks() }
        // The hub says what comes now: a first sitting, or a later opening whose root step brought an app. A hub from
        // before the choice has nothing to read, and has both.
        for _ in 0..<30 {       // a question of macOS can hold this Mac's first call for as long as nobody answers it
            switch await readNeeds() {
            case .needs(let needs):
                self.needs = needs
                plan = needs.plan
                return needs.inSitting ? advance() : show(.checking)
            case .older: return advance()
            case .left, .unread: try? await Task.sleep(for: .seconds(2))
            }
        }
        stop(Self.noHub)
    }

    private func readFileVault() async {
        let said = try? await LocalShell.run("/usr/bin/fdesetup", ["status"], timeout: 20)
        fileVault = MacSittingRead.fileVaultOn(said?.output ?? "")
    }

    /// The owner's app takes this Mac's own checks and goes on: the rest of the sitting needs it no more.
    private func reportChecks() async {
        let done = MacInstallState(state: "done", says: "This Mac is in your fleet.")
        guard let checked = try? await LocalShell.sh(InstallPlan.verifyCommand(.macWorker), timeout: 600),
              let checklist = VerifyChecklist.read(output: checked.output, readAt: Date().timeIntervalSince1970) else {
            return update(done)
        }
        update(MacInstallState(state: "done", says: done.says, verify: checklist.checks))
    }

    private func update(_ new: MacInstallState) {
        state = new
        listener?.update(new)
    }

    // MARK: One page at a time

    private func advance() {
        if var left = missing {
            guard !left.isEmpty else { return show(needs?.state == "stopped" ? .finish : .nothingMissing) }
            let next = left.removeFirst()
            missing = left
            return show(next)
        }
        if let next = page.next(fileVault: fileVault, plan: plan) { show(next) }
    }

    private func show(_ next: MacSittingPage, cameBack: Bool = false) {
        page = next
        failure = nil
        working = false
        self.cameBack = cameBack
        watch?.cancel()
        // The owner was in Chrome or in Settings: the next step comes to him. macOS no longer lets an app take the
        // keyboard from another one, so the window comes over them.
        NSApplication.shared.activate()
        NSApplication.shared.windows.forEach { $0.orderFrontRegardless() }
        if next.isSmallWindow { keepInView() }
        try? MacSittingRecord(page: next, run: next == .setup ? run : nil).write(Self.record)
        guard !cameBack else { return }
        switch next {
        case .automaticLogin: watchAutomaticLogin()
        case .claude: watchClaude()
        case .appleEvents: watchAppleEvents()
        case .chatGPT: watchChatGPT()
        case .computerUse: watchComputerUse()
        case .checking: check()
        case .nothingMissing:
            addable = ServerAI.linuxChoices.filter { !adding.contains($0) && ($0 == .claude ? needs?.browser : needs?.chatgpt) != true }
        case .lockScreen, .finish, .link, .setup: break
        }
        // A Chrome that an agent may work in restarts only at his press, in a later opening.
        if missing == nil || next != .claude || adding.contains(.claude) { open() }
    }

    /// From the first page of the sitting the window is small and stays above Chrome and System Settings, so the owner
    /// never closes them to reach it. It moves to the bottom left once, and from there he can drag it: macOS's own
    /// notices and Chrome's prompt for the extension stand at the top right, and would cover it or be covered.
    private func keepInView() {
        NSApplication.shared.windows.forEach { $0.level = .floating }
        guard !placed, let window = NSApplication.shared.windows.first(where: \.canBecomeMain),
              let area = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        placed = true
        // In a moment: the window's smaller limits reach it with the next drawing of the page.
        DispatchQueue.main.async {
            let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.smallWidth, height: Self.smallHeight)).size
            window.setFrame(NSRect(x: area.minX + 16, y: area.minY + 16, width: size.width, height: size.height), display: true)
        }
    }

    private func watching(_ work: @escaping @MainActor (InstallerModel) async -> Void) {
        watch?.cancel()
        watch = Task { [weak self] in
            guard let self else { return }
            await work(self)
        }
    }

    private func watchAutomaticLogin() {
        let user = user
        watching { model in
            while !Task.isCancelled {
                let said = try? await LocalShell.run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.loginwindow",
                                                                           "autoLoginUser"], timeout: 20)
                guard !Task.isCancelled else { return }
                if MacSittingRead.automaticLogin(said?.output ?? "", user: user) { return model.advance() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// One sign-in in Chrome serves the extension and Claude Code, and each then asks its own Authorize. The extension
    /// comes first, because Chrome offers it once at its start. Then Claude Code's own sign-in opens in the same Chrome,
    /// and its callback stays on this Mac: no code crosses the hub. The extension's own page comes after it. The page
    /// goes on when this Mac's Chrome has opened a page that only this Mac can reach (`LocalProofPage`): a browser in
    /// the runtime's list may stand on another Mac of the same account.
    private func watchClaude() {
        watching { model in
            var absent = 0, unanswered = 0
            while !Task.isCancelled {
                guard FileManager.default.isExecutableFile(atPath: model.claude) else {
                    absent += 1
                    if absent >= Self.claudeWaits { return model.stop("Claude Code did not install. Look at this server in Founderizer.") }
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                let desktop = await model.readDesktop()
                let signedIn = await model.claudeCodeSignedIn()
                guard !Task.isCancelled else { return }
                if desktop?.extension == true, !signedIn { model.signInClaudeCode() }
                if signedIn { model.toExtension = true }
                if signedIn, desktop?.browser != true {
                    await model.bringExtensionSignIn()
                    unanswered += 1
                    if unanswered >= Self.browserWaits { return model.stop(Self.noAnswer) }
                }
                if signedIn, desktop?.browser == true {
                    // A later opening pays for no model of its own: Chrome was closed, and it answers again.
                    if model.missing != nil, !model.adding.contains(.claude) { return model.advance() }
                    let passed = await model.browserTaskPassed()
                    guard !Task.isCancelled else { return }
                    if passed { return model.advance() }
                    model.tries += 1
                    if model.tries >= 3 { return model.stop(Self.noAnswer) }
                }
                try? await Task.sleep(for: .seconds(signedIn ? 1 : 3))
            }
        }
    }

    private func claudeCodeSignedIn() async -> Bool {
        MacSittingRead.claudeSignedIn((try? await LocalShell.run(claude, ["auth", "status"], timeout: 30))?.output ?? "")
    }

    /// The extension's own Authorize comes forward, once.
    private func bringExtensionSignIn() async {
        guard !reconnected else { return }
        reconnected = true
        openInChrome([Self.reconnect, await extensionSignIn() ?? Self.extensionLogin])
    }

    // MARK: A later opening

    /// The installer opened on a Mac that has joined: free readings find what is missing for what this Mac needs, and it
    /// leads those pages alone. Nothing here pays for a model or restarts Chrome, and a reading that fails says so: it
    /// never reads as nothing missing.
    private func check() {
        working = true
        watching { model in
            let reading = await model.readNeeds()
            guard !Task.isCancelled else { return }
            switch reading {
            case .left, .older: model.show(.link)
            case .unread: model.stop(Self.noHub)
            case .needs(let needs):
                model.needs = needs
                model.plan = needs.plan
                if needs.inSitting { return await model.goOn(from: nil) }
                let wanted = [Self.chromeApp] + (needs.chatgpt == true || model.adding.contains(.chatGPT) ? [Self.chatGPTApp] : [])
                if wanted.contains(where: { !FileManager.default.fileExists(atPath: $0) }) { return model.startRootStep() }
                let pages = await model.missingPages(needs)
                guard !Task.isCancelled else { return }
                model.missing = pages
                model.advance()
            }
        }
    }

    private func missingPages(_ needs: MacNeeds) async -> [MacSittingPage] {
        var pages: [MacSittingPage] = []
        if !fileVault {
            let said = try? await LocalShell.run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.loginwindow",
                                                                       "autoLoginUser"], timeout: 20)
            if !MacSittingRead.automaticLogin(said?.output ?? "", user: user) { pages.append(.automaticLogin) }
        }
        if needs.locked == true { pages.append(.lockScreen) }           // macOS gives no other reading of this setting
        if needs.browser == true {
            let desktop = await readDesktop(), signedIn = await claudeCodeSignedIn()
            if !signedIn || desktop?.extension != true || desktop?.browser != true { pages.append(.claude) }
        }
        if FileManager.default.fileExists(atPath: Self.vault.path), !appleEventsAllowed() { pages.append(.appleEvents) }
        if needs.chatgpt == true || adding.contains(.chatGPT) {
            if !(await chatGPTSignedIn(Self.chatGPT)) {
                pages += [.chatGPT, .computerUse]
            } else if needs.screen_task != true, !(await ComputerUseProof.screenshot(codex: Self.chatGPT)) {
                screenAsked = true
                pages.append(.computerUse)
            }
        }
        return pages
    }

    /// Add ChatGPT or Add Claude, at this Mac: that AI's pages, and the hub reads the rest from this Mac's next report.
    func add(_ ai: ServerAI) {
        guard !secondClick else { return }
        working = true
        adding.insert(ai)
        watching { model in
            if ai == .claude {
                let said = try? await LocalShell.sh("python3 \"$HOME/fleet-server/server.py\" add-claude", timeout: 960)
                guard !Task.isCancelled else { return }
                guard said?.ok == true else {
                    model.adding.remove(ai)
                    return model.stop(said?.lines.last ?? "Claude Code did not install. Try again.")
                }
                model.chromeStarted = false
                model.missing = [.claude]
                return model.advance()
            }
            guard FileManager.default.fileExists(atPath: Self.chatGPTApp) else { return model.startRootStep() }
            model.missing = [.chatGPT, .computerUse]
            model.advance()
        }
    }

    /// The page and its button take the owner to what the sign-in needs now, whatever became of Chrome's window. Chrome
    /// reads its extension file at its start alone, so a Chrome that has not read it starts once more, and its tabs
    /// come back with it. Chrome offers the extension once: a prompt that went never comes back, also after a restart,
    /// so an extension that is off gets Chrome's own page with its switch, which opens the same sign-in. One that the
    /// owner removed gets its page in the Web Store: Chrome does not take its file again. A reading that did not
    /// answer, or a page he has left, never closes his Chrome.
    private func openChrome() {
        guard !opening else { return }
        opening = true
        Task {
            defer { opening = false }
            let desktop = await readDesktop()
            guard page == .claude else { return }
            // Null: no profile has the extension yet, which also holds while Chrome fetches it after its start.
            if let desktop, desktop.extension == nil, !chromeStarted {
                chromeStarted = true
                return await restartChrome()
            }
            var tabs: [String] = []
            if let desktop, desktop.extension != true {
                tabs.append(desktop.extension == false ? Self.extensionPage : Self.extensionStore)
            } else if toExtension {
                tabs.append(Self.extensionLogin)
            } else {
                if desktop?.browser != true, let address = await extensionSignIn() { tabs.append(address) }
                if signingIn, let address = try? String(contentsOf: Self.signInAddress, encoding: .utf8) { tabs.append(address) }
            }
            _ = try? await LocalShell.run("/usr/bin/open", ["-a", Self.chromeApp] + tabs)
        }
    }

    private func restartChrome() async {
        let chrome = InstallerModel.quoted(Self.chromeApp)
        _ = try? await LocalShell.sh("""
            if pkill -TERM -x 'Google Chrome'; then
                i=0
                while pgrep -x 'Google Chrome' >/dev/null && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
                exec /usr/bin/open -a \(chrome) --args --restore-last-session
            fi
            exec /usr/bin/open -a \(chrome)
            """)
    }

    /// The extension's own sign-in holds a code that the extension made, so a new one would need a new start of its
    /// flow. Chrome's history names the one that it opened. The address carries no credential and stays on this Mac.
    private func extensionSignIn() async -> String? {
        let history = Self.home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History")
        let copy = Self.work.appendingPathComponent("history")
        defer { try? FileManager.default.removeItem(at: copy) }
        try? FileManager.default.removeItem(at: copy)
        guard (try? FileManager.default.copyItem(at: history, to: copy)) != nil else { return nil }
        let said = try? await LocalShell.run("/usr/bin/sqlite3", ["-readonly", copy.path, Self.extensionSignInQuery], timeout: 20)
        guard said?.ok == true, let address = said?.output.trimmingCharacters(in: .whitespacesAndNewlines),
              address.hasPrefix("https://claude.ai/oauth/authorize?") else { return nil }
        return address
    }

    private struct Desktop: Decodable {
        let `extension`: Bool?
        let browser: Bool?
    }

    /// This Mac's own reading (`server.py desktop`), which the fleet's status report sends too.
    private func readDesktop() async -> Desktop? {
        let said = try? await LocalShell.sh("python3 \"$HOME/fleet-server/server.py\" desktop", timeout: 60)
        return (said?.output).flatMap { try? JSONDecoder().decode(Desktop.self, from: Data($0.utf8)) }
    }

    /// The runtime in the same Chrome: a new Mac's default browser is Safari, where nothing is signed in.
    private func inChrome() -> String {
        let opener = Self.work.appendingPathComponent("chrome-open")
        try? FileManager.default.createDirectory(at: Self.work, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let keep = InstallerModel.quoted(Self.signInAddress.path)
        try? Data("#!/bin/sh\nprintf '%s' \"$1\" > \(keep)\nexec /usr/bin/open -a \(InstallerModel.quoted(Self.chromeApp)) \"$1\"\n".utf8)
            .write(to: opener, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: opener.path)
        return "BROWSER=" + InstallerModel.quoted(opener.path) + " " + InstallerModel.quoted(claude)
    }

    private func signInClaudeCode() {
        guard !signingIn else { return }
        signingIn = true
        try? FileManager.default.removeItem(at: Self.signInAddress)
        let command = inChrome(), hold = InstallerModel.quoted(Self.work.appendingPathComponent("hold").path)
        Task {
            // Its standing input stays open, in a pipe that this shell holds: it also waits there for a code that
            // nobody types, and it ends when the runtime ends. No clock ends it: each new sign-in would be one more
            // tab, and this one stays good for as long as the owner is away.
            _ = try? await LocalShell.sh("rm -f \(hold); mkfifo \(hold); exec 3<>\(hold); rm -f \(hold); "
                                         + "exec env " + command + " auth login <&3", timeout: .infinity)
            // After the reading: the loop must not start a second sign-in on what it read just before this one ended.
            let signedIn = await claudeCodeSignedIn()
            signingIn = false
            // He has just pressed Authorize, so the next one comes to him now and not at the next reading.
            guard signedIn, page == .claude, !cameBack else { return }
            toExtension = true
            await bringExtensionSignIn()
        }
    }

    private func openInChrome(_ addresses: [String]) {
        Task { _ = try? await LocalShell.run("/usr/bin/open", ["-a", Self.chromeApp] + addresses) }
    }

    /// The page's script answers, or the task proved nothing, whatever its words say. Its answer is all the proof, so
    /// the next page comes with it, and the task ends by itself behind it.
    private func browserTaskPassed() async -> Bool {
        let page = LocalProofPage()
        guard let address = try? page.start() else { return false }
        defer { page.stop() }
        working = true
        defer { working = false }
        let task = inChrome() + " -p --chrome --model haiku --permission-mode dontAsk "
            + "--allowedTools 'mcp__claude-in-chrome__*'"
        var ended = false
        Task {
            _ = try? await LocalShell.sh(task, stdin: Data(Self.proof(address).utf8), timeout: 180)
            ended = true
        }
        while !ended, !page.seen, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)) }
        return page.seen
    }

    /// Chrome takes this menu item from a real keyboard or mouse alone, so nothing here can press it. The page reads
    /// Chrome's own preferences. Then one harmless script runs through this Mac's vault, so that macOS asks its one
    /// question for the vault now, with a person here: the vault's later sign-ins have nobody to answer it.
    private func watchAppleEvents() {
        watching { model in
            while !Task.isCancelled {
                if model.appleEventsAllowed() {
                    model.working = true
                    let said = try? await LocalShell.sh("python3 \"$HOME/fleet-server/server.py\" chrome-script", timeout: 300)
                    guard !Task.isCancelled else { return }
                    guard said?.output.contains("\"ok\": true") == true || said?.output.contains("\"ok\":true") == true else {
                        return model.stop("Chrome did not take the vault's script. In System Settings, Privacy & Security, "
                                          + "Automation, allow Fleet Vault to control Chrome.")
                    }
                    return model.advance()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func appleEventsAllowed() -> Bool {
        let chrome = Self.home.appendingPathComponent("Library/Application Support/Google/Chrome")
        let profiles = (try? FileManager.default.contentsOfDirectory(atPath: chrome.path)) ?? []
        return profiles.contains { profile in
            (try? Data(contentsOf: chrome.appendingPathComponent(profile).appendingPathComponent("Preferences")))
                .map(MacSittingRead.appleEventsAllowed) == true
        }
    }

    /// The page goes on when the app is signed in, and a Codex agent's own copy, which its install job brings, reads
    /// the same sign-in: a fault there would show only when the monitor is gone.
    private func watchChatGPT() {
        watching { model in
            var absent = 0
            while !Task.isCancelled {
                let signedIn = await model.chatGPTSignedIn(Self.chatGPT)
                guard !Task.isCancelled else { return }
                if signedIn {
                    guard model.needs?.own_copy == true else { return model.advance() }
                    if await model.chatGPTSignedIn(model.agentCodex) { return model.advance() }
                    guard !Task.isCancelled else { return }
                    model.working = true
                    absent += 1
                    if absent >= Self.codexWaits { return model.stop("Codex did not install. Look at this server in Founderizer.") }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func chatGPTSignedIn(_ codex: String) async -> Bool {
        MacSittingRead.chatGPTSignedIn((try? await LocalShell.run(codex, ["login", "status"], timeout: 20))?.output ?? "")
    }

    /// One real screenshot opens OpenAI's own window, which leads both permissions: macOS lists its helper on Screen
    /// Recording only through that window. The window lives as long as its helper, and only the helper of the ChatGPT
    /// app outlives this call, so the call waits for that one. ChatGPT starts it at its sign-in, and a call in its first
    /// seconds opened no window (4 November 2026), so a call that ends with no window comes again. No call comes while
    /// the window stands: it would take the keyboard from a password that the owner types there. The spinner stands
    /// until the window does, and the line and Next come with it.
    private func watchComputerUse() {
        guard !screenAsked else { return screenAsked = false }
        working = true
        watching { model in
            await model.waitForChatGPTHelper()
            for _ in 0..<Self.windowCalls {
                guard !Task.isCancelled else { return }
                let passed = await model.screenshotTillTheWindow()
                guard !Task.isCancelled else { return }
                if passed { return model.advance() }
                if !model.working { return }        // the window came: its steps are the owner's, and so is Next
            }
            model.working = false
        }
    }

    /// One call of the proof. The spinner goes as soon as OpenAI's window is on the screen, and the call goes on.
    private func screenshotTillTheWindow() async -> Bool {
        let codex = Self.chatGPT
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await ComputerUseProof.screenshot(codex: codex) }
            group.addTask {                     // nil: OpenAI's window is on the screen
                while !Task.isCancelled, !ComputerUseProof.windowShows() { try? await Task.sleep(for: .seconds(1)) }
                return nil
            }
            for await answer in group {
                guard let answer else {
                    if !Task.isCancelled { working = false }   // a page that came meanwhile keeps its own spinner
                    continue
                }
                group.cancelAll()
                return answer
            }
            return false
        }
    }

    private func waitForChatGPTHelper() async {
        var looks = 0
        while looks < 30, !Task.isCancelled {
            let said = try? await LocalShell.sh("pgrep -P \"$(pgrep -x ChatGPT | head -n 1)\" -f SkyComputerUseService", timeout: 10)
            if said?.ok == true { return }
            looks += 1
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Next's proof. One that fails while OpenAI's window still stands leaves the page as it was, with no orange line:
    /// the owner is at that window's steps (his words of 4 November 2026: "it showed this while I was doing the
    /// accessibility steps").
    private func proveComputerUse() {
        working = true
        watching { model in
            await model.waitForChatGPTHelper()
            let passed = await ComputerUseProof.screenshot(codex: Self.chatGPT)
            guard !Task.isCancelled else { return }
            if passed { return model.advance() }
            if ComputerUseProof.windowShows() { model.working = false } else { model.stop(Self.noScreen) }
        }
    }

    // MARK: What the owner presses

    /// Each page opens what it is about when it appears, and its button opens it again.
    private func open() {
        if let address = page.settings { NSWorkspace.shared.open(address); return }
        switch page {
        case .claude: openChrome()
        case .appleEvents: Task { _ = try? await LocalShell.run("/usr/bin/open", ["-a", Self.chromeApp]) }
        case .chatGPT: Task { _ = try? await LocalShell.run("/usr/bin/open", ["-a", Self.chatGPTApp]) }
        case .computerUse: Task { _ = try? await LocalShell.run("/usr/bin/open", ["-g", "-a", Self.chatGPTApp]) }
        default: break
        }
    }

    /// The page's one button.
    func act() {
        switch page {
        case .finish: finish()
        case .nothingMissing: done()
        default: open()
        }
    }

    /// The end of a later opening: nothing stays of it.
    private func done() {
        try? FileManager.default.removeItem(at: Self.record)
        NSApplication.shared.terminate(nil)
    }

    /// The page before. It undoes nothing that the owner did in macOS or Chrome.
    func back() {
        guard canGoBack, !secondClick, let before = page.previous(fileVault: fileVault, plan: plan) else { return }
        show(before, cameBack: true)
    }

    /// The second click of a double click is not a press on the page that the first one brought.
    private var secondClick: Bool {
        guard let event = NSApplication.shared.currentEvent, event.type == .leftMouseUp else { return false }
        return event.clickCount > 1
    }

    /// macOS hides what the owner set on this page, so his word goes on. Computer Use can show that it works.
    func next() {
        guard !secondClick else { return }
        if page == .computerUse, !cameBack { proveComputerUse() } else { advance() }
    }

    func tryAgain() {
        failure = nil
        tries = 0
        if page == .setup, order != nil || joinedBefore {
            startRootStep()
        } else if page == .setup {
            show(.link)         // no order is left after a restart of this app: the owner's app sends a new one
            listener?.takeAgain(MacInstallState(state: "waiting", says: "Waiting for your app."))
        } else {
            show(page)
        }
    }

    /// The last press: the hub goes on with this Mac's proof, and this Mac restarts once. A Mac with FileVault on does
    /// not, because a person would have to unlock it. The rest happens with nobody here.
    private func finish() {
        guard !finishing else { return }
        finishing = true
        working = true
        Task {
            defer { finishing = false }
            let restart = !fileVault && missing == nil      // a later opening never restarts a Mac that works
            let said = try? await LocalShell.sh("python3 \"$HOME/fleet-server/server.py\" finish" + (restart ? "" : " --no-restart"),
                                                timeout: 60)
            guard said?.ok == true else { return stop(said?.lines.last ?? "Your hub did not answer. Try again.") }
            try? FileManager.default.removeItem(at: Self.loginItem)
            try? FileManager.default.removeItem(at: Self.record)
            try? FileManager.default.removeItem(at: Self.work)
            if restart { FileManager.default.createFile(atPath: Self.restartMark, contents: nil) }
            NSApplication.shared.terminate(nil)
        }
    }

    /// What stopped this page. Before the join the owner's app may send a new order: its Try again makes a new join
    /// code, so the order that this Mac holds may be dead.
    private func stop(_ says: String) {
        failure = says
        working = false
        guard state.state != "done" else { return }
        state = MacInstallState(state: "failed", says: says)
        listener?.takeAgain(state)
    }

    // MARK: What this Mac is

    /// One shell word, for a command inside another one.
    nonisolated private static func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Runs one command as root behind macOS's own password dialog. The password goes to macOS alone. This blocks the
    /// main thread while the dialog stands, and the command leaves itself in the background, so it ends at once.
    private static func asAdministrator(_ command: String, prompt: String) -> Bool {
        func text(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \(text(command)) with prompt \(text(prompt)) with administrator privileges")?
            .executeAndReturnError(&error)
        return error == nil
    }

    /// The Tailscale command line of this Mac, wherever it came from.
    nonisolated static func tailscale() -> String? {
        ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
         "/Applications/Tailscale.app/Contents/MacOS/Tailscale"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    nonisolated static func onTheNetwork() async -> Bool {
        guard let cli = tailscale() else { return false }
        return (try? await LocalShell.run(cli, ["status"], timeout: 30))?.ok == true
    }

    /// This Mac's own model, for the one warning that matters: never a laptop.
    nonisolated static func modelName() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0, size < 256 else { return "This Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    /// The addresses of this Mac on its own networks, which the owner reads off this screen and types once.
    nonisolated static func ownAddresses() -> [String] {
        var found: [String] = []
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return found }
        defer { freeifaddrs(first) }
        var each = first
        while let one = each {
            let flags = Int32(one.pointee.ifa_flags)
            let name = String(cString: one.pointee.ifa_name)
            if let address = one.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
               flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(cString: host)
                    if !text.isEmpty, !found.contains(text), !name.hasPrefix("utun") || text.hasPrefix("100.") {
                        found.append(text)
                    }
                }
            }
            each = one.pointee.ifa_next
        }
        return found
    }
}
