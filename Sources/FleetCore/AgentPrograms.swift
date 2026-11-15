import Foundation

/// **Which of the two agent programs are on this Mac: Claude Code and Codex** (the owner, 14 November 2026: "during app
/// onboarding, I mentioned that I wanted to detect whether user had codex/claude installed and have just a prompt ready
/// for user to copy it, which instructs the agent to install the admin mcp and follow the instructions in the
/// agent-install.md"; and of the moving mock of the first run's welcome page: "I have Codex and Claude, not only claude.
/// Your images show the claude icon only... maybe we should not show any specific icon there?"). The welcome page names
/// the ones found in the words of its second way, and shows no second way when neither is here.
///
/// It looks at fixed places and not at `PATH`: an app that the Finder starts has a short one, with none of the folders
/// that the programs' installers write to. It starts no process, reads no sign-in state and keeps no account: a file of
/// the right kind at one of the places is all that it asks.
public enum AgentPrograms {
    public enum Program: String, CaseIterable, Sendable {
        case claudeCode, codex
    }

    /// The kind of a thing at a path, through every link, as the places need it.
    public enum Kind: Equatable, Sendable {
        case none
        case file(executable: Bool)
        case folder
    }

    /// What the places are read with: this Mac's disk, or a test's own.
    public struct Disk: Sendable {
        public let kind: @Sendable (String) -> Kind
        public let names: @Sendable (String) -> [String]

        public init(kind: @escaping @Sendable (String) -> Kind, names: @escaping @Sendable (String) -> [String]) {
            self.kind = kind
            self.names = names
        }

        /// This Mac's disk, through every link: a link whose target is gone is nothing.
        public static let mac = Disk(kind: { path in
            var folder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &folder) else { return .none }
            return folder.boolValue ? .folder : .file(executable: FileManager.default.isExecutableFile(atPath: path))
        }, names: { path in
            (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        })
    }

    /// The programs on this Mac. `root` stands for "/" and `home` for the user's home folder: a test gives a scratch
    /// folder for each.
    public static func found(home: URL = URL(fileURLWithPath: NSHomeDirectory()), root: URL = URL(fileURLWithPath: "/"),
                             disk: Disk = .mac) -> Set<Program> {
        Set(Program.allCases.filter { isHere($0, home: home, root: root, disk: disk) })
    }

    /// The names of the programs found, for the words of the welcome page and of the page after its press: "Claude
    /// Code or Codex", "Claude Code", "Codex", or nil when neither is on this Mac.
    public static func names(_ found: Set<Program>) -> String? {
        switch (found.contains(.claudeCode), found.contains(.codex)) {
        case (true, true): String(l10n: "Claude Code or Codex")
        case (true, false): "Claude Code"
        case (false, true): "Codex"
        case (false, false): nil
        }
    }

    /// The title of the welcome page's second way: "Let Claude Code or Codex do it", or nil when the way is not there.
    public static func wayTitle(_ found: Set<Program>) -> String? {
        names(found).map { String(l10n: "Let \($0) do it") }
    }

    /// The title of the page after the press: "Paste this in Claude Code or Codex", with the names of both when neither
    /// was found (a look at that page with `-firstRunStep paste`).
    public static func pasteTitle(_ found: Set<Program>) -> String {
        let names = names(found) ?? String(l10n: "Claude Code or Codex")
        return String(l10n: "Paste this in \(names)")
    }

    static func isHere(_ program: Program, home: URL, root: URL, disk: Disk) -> Bool {
        func inRoot(_ path: String) -> String { root.appendingPathComponent(path).path }
        func inHome(_ path: String) -> String { home.appendingPathComponent(path).path }
        func runs(_ path: String) -> Bool { disk.kind(path) == .file(executable: true) }
        func app(_ path: String) -> Bool {
            disk.kind(path) == .folder && disk.kind(path + "/Contents") == .folder
        }
        switch program {
        case .claudeCode:
            let places = [inHome(".local/bin/claude"), inRoot("opt/homebrew/bin/claude"), inRoot("usr/local/bin/claude"),
                          inHome(".claude/local/claude")]
            if places.contains(where: runs) { return true }
            // The native installer keeps each version as one program in this folder, and links `~/.local/bin/claude`
            // to the newest; a version with no link is still Claude Code.
            let versions = inHome(".local/share/claude/versions")
            if disk.kind(versions) == .folder,
               disk.names(versions).contains(where: { !$0.hasPrefix(".") && runs(versions + "/" + $0) }) { return true }
            // **The copy that the Claude desktop app keeps for its own Code tab**, seen read only on a Mac of 14 November
            // 2026: `~/Library/Application Support/Claude/claude-code/<version>/<build>/claude.app/Contents/MacOS/claude`.
            let desktop = inHome("Library/Application Support/Claude/claude-code")
            guard disk.kind(desktop) == .folder else { return false }
            for version in disk.names(desktop) where !version.hasPrefix(".") {
                let folder = desktop + "/" + version
                guard disk.kind(folder) == .folder else { continue }
                for build in disk.names(folder) where !build.hasPrefix(".") {
                    if runs(folder + "/" + build + "/claude.app/Contents/MacOS/claude") { return true }
                }
            }
            return false
        case .codex:
            let places = [inHome(".local/bin/codex"), inRoot("opt/homebrew/bin/codex"), inRoot("usr/local/bin/codex")]
            if places.contains(where: runs) { return true }
            // The Codex desktop app, in the Mac's Applications or in the user's own.
            return [inRoot("Applications/Codex.app"), inHome("Applications/Codex.app")].contains(where: app)
        }
    }
}

/// **The one prompt that the welcome page copies for the owner's own agent** (the owner's yes of 14 November 2026 to
/// the page after the press). The address is the guide's page on the website, in both languages.
public enum AgentPrompt {
    public static let english = "Install the Founderizer admin MCP, then guide me through my fleet setup. "
        + "Follow the instructions here: https://founderizer.com/agent-install.md"
    public static let spanish = "Instala el MCP de administración de Founderizer y guíame en la configuración de mi "
        + "equipo. Sigue las instrucciones de aquí: https://founderizer.com/agent-install.md"

    /// The prompt in the language that the app shows its words in (`Localized.bundle`): this is what is copied.
    public static var shown: String { prompt(language: language(of: Localized.bundle)) }

    /// Spanish for a Spanish language ("es", "es-MX"), and English for every other one and for none.
    public static func prompt(language: String?) -> String {
        language.map { $0 == "es" || $0.hasPrefix("es-") || $0.hasPrefix("es_") } == true ? spanish : english
    }

    /// The language of the words that a bundle gives: the app's first language for this user, or the language of a
    /// table that is one language's folder (`es.lproj`, which a test gives its own task).
    static func language(of bundle: Bundle) -> String? {
        bundle.bundleURL.pathExtension == "lproj" ? bundle.bundleURL.deletingPathExtension().lastPathComponent
            : bundle.preferredLocalizations.first
    }

    /// **The prompt as the page after the press shows it: the sentence, then the address on a line of its own**, so that
    /// the address never breaks after `https://`. Only the space before the address becomes a line break; what is copied
    /// is the prompt itself, on one line.
    public static func lines(_ prompt: String) -> String {
        guard let address = prompt.range(of: " https://", options: .backwards) else { return prompt }
        return prompt.replacingCharacters(in: address.lowerBound..<prompt.index(after: address.lowerBound), with: "\n")
    }
}

/// **The first run's pages before the VPS page, as rules with no view** (`FirstRunModel` in the app follows them).
///
/// **The welcome page shows at one more moment** (the owner's yes of 14 November 2026, to "An unfinished setup opens
/// on the welcome page, with its two ways; 'Set it up yourself' goes on where the setup stands": "yes there should be
/// always a way to see it"): in each start of the app, the first time that the window would show the setup of a
/// manager that has no server yet, the welcome page stands in front of it (`coversSetup`), until one of its ways is
/// taken, the owner leaves that page (`leaves`), or an install or a build of a server runs in that start. A fleet
/// exists then, so the page's first way and the guide's sign
/// lead to that setup and not to the first run's next page (`firstWay`), and the page looks for no fleet
/// (`looksForAFleet`).
public enum WelcomeRules {
    /// The pages of the first run, as these rules tell them apart.
    public enum Page: Sendable {
        /// The welcome page: the team, its title and its two ways.
        case welcome
        /// The page after the press on the second way: the prompt to paste.
        case paste
        /// "A VPS for your fleet", the page of the first way.
        case cloud
        /// "Name your manager", the first page of the first way, which the sign of the owner's own agent opens too.
        case name
        /// Any other page of the first run.
        case other
    }

    /// **The owner's own agent started the guide** (`founderizer-cli guide`): the app goes to "Name your manager", the
    /// first page of the first way, and comes to the front, only while the welcome page or the page after it shows and no connect of the wizard runs (the owner's
    /// "Yes" of 14 November 2026 to "May the app come to the front by itself when your own agent needs you there?").
    /// Any process of the user can send that notification, so in every other state it does nothing. **An install that
    /// began and stopped does not stop it** (`atStart`): back on these two pages the wizard is at its start again. No
    /// install or build runs while these pages show: a page that runs one has no Back.
    public static func guideTakesTheApp(on page: Page, busy: Bool) -> Bool {
        atStart(page) && !busy
    }

    /// Where the welcome page's first way leads, and the sign of `founderizer-cli guide` with it.
    public enum FirstWay: Equatable, Sendable {
        /// The first run of a Mac that has no fleet goes on with its own next page.
        case firstRun
        /// The setup of the fleet's manager, at the page where it stands: a fleet whose setup never finished.
        case managerSetup
    }

    /// **"Set it up yourself" goes on where the setup stands.** With no fleet that is the first run's own next page.
    /// With a fleet whose manager has no server yet it is the manager's own setup, which opens on its server's page,
    /// or on its provider's when a server joined for it already. The guide's sign goes the same way: an agent that
    /// starts the guide on a Mac whose fleet exists must never be led to a page that makes a second hub.
    public static func firstWay(fleet: Bool) -> FirstWay { fleet ? .managerSetup : .firstRun }

    /// **Whether the welcome page stands in front of the manager's setup now.** All of these hold: the hub's address
    /// had answered this Mac in an earlier start of the app (`hadFleet`; a first run of this start went through the
    /// welcome page already); the page was not passed in this start (`passed`: a way was taken, the owner left the
    /// manager's page, an install or a build of a server ran, the manager got its server, or a page was asked for
    /// with a launch argument); this Mac has a
    /// program for the page's second way (`offersAgent`: without one the page has one card, which only leads to the
    /// page behind it); the manager has no server yet (`unplaced`); the window would show that manager's setup alone
    /// (`setupFills`); and no install and no build of a server runs (`runs`). **Work that runs is never covered**: its
    /// page is the one that says how it stands.
    public static func coversSetup(hadFleet: Bool, passed: Bool, offersAgent: Bool, unplaced: Bool, setupFills: Bool,
                                   runs: Bool) -> Bool {
        hadFleet && !passed && offersAgent && unplaced && setupFills && !runs
    }

    /// **The owner left the manager's page, so the welcome page in front of it is passed for this start of the app.**
    /// `chosen`: the app had its first page already (the page that the app itself opens on is no page that the owner
    /// left). `fromManager`: the page before was the manager's own. `changed`: another page shows now. A start that
    /// opens on another page (a request that waits) passes nothing: the welcome page then shows when the owner first
    /// opens the manager, unless an install or a build of a server ran in that start meanwhile, which passes it too.
    public static func leaves(chosen: Bool, fromManager: Bool, changed: Bool) -> Bool {
        chosen && fromManager && changed
    }

    /// The welcome page and the page after its press are the wizard's start, whatever an earlier install of this session
    /// did: from there the owner chooses a way again.
    public static func atStart(_ page: Page) -> Bool {
        switch page {
        case .welcome, .paste: true
        case .cloud, .name, .other: false
        }
    }

    /// Where Back goes from these pages: from the page after the press, from the name page and from the VPS page to
    /// the welcome page (the first run sends the VPS page back to the name page when the owner came through it). The
    /// welcome page has no Back; nil for a page that these rules do not decide.
    public static func back(from page: Page) -> Page? {
        switch page {
        case .paste, .cloud, .name: .welcome
        case .welcome, .other: nil
        }
    }

    /// **Whether the first run looks for a fleet that the owner's own agent made now** (`findFleet`). On the welcome
    /// page and the page after its press, where the owner waits while their agent works, whenever no connect runs: the
    /// wizard is at its start there (`atStart`). On the VPS page only while no install of this session began, so that it
    /// never connects to a hub that an install left half made. **On the name page as on the VPS page**: the sign of
    /// the owner's own agent opens that page, and the agent can install a hub by itself while the page shows, so a
    /// page that did not look would stand over a fleet that runs. **Never while a fleet is connected already** (`fleet`:
    /// the welcome page of an unfinished setup): a look would connect a second time and take the window to the first
    /// run's last page.
    public static func looksForAFleet(on page: Page, began: Bool, busy: Bool, fleet: Bool = false) -> Bool {
        guard !fleet else { return false }
        return switch page {
        case .welcome, .paste: !busy
        case .cloud, .name: !began && !busy
        case .other: false
        }
    }

    /// **Whether a new build of the app may go in by itself now** (`AppUpdatePolicy.setupHolds`, through the app's
    /// `setupAtRest`): its restart opens the first run on the welcome page again. That takes nothing away on the welcome
    /// page or on the VPS page while no install of this session began and no connect runs. **Never on the page after
    /// the press**: the owner waits there for their agent, and a restart would lose the agent's sign. **Never on the name
    /// page**: the owner types there, and a restart would lose the typed name.
    public static func atRest(on page: Page, began: Bool, busy: Bool) -> Bool {
        switch page {
        case .welcome, .cloud: !began && !busy
        case .paste, .name, .other: false
        }
    }
}
