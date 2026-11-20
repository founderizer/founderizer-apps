import Foundation

/// **One sitting at a new Mac** (the owner, 31 October 2026: "it has to be truly smooth!", and his yes to these pages).
/// A new Mac needs a person for Apple's own setup, and a Claude sign-in must end on Anthropic's own page, so a person
/// sits there once, and the installer leads every step of that sitting. Each page is one thing to do, and it opens the
/// app it is about when it appears. A page that can read its own result goes on by itself; only the pages that macOS
/// hides from other apps have a Next, and so has a page that the owner reached with Back.
public enum MacSittingPage: String, Codable, CaseIterable, Sendable {
    /// The address and the link code, for Founderizer on the owner's own Mac.
    case link
    /// The one root step: the tools, the apps, this Mac's settings and the join. Nothing to do.
    case setup
    case automaticLogin, lockScreen, claude, appleEvents, chatGPT, computerUse, finish
    /// The installer opened again on a Mac that has joined (the owner, 1 November 2026: "improve the installer app so it
    /// finds "missing" config/permissions"): it looks, and leads only what is missing.
    case checking, nothingMissing

    public var title: String {
        switch self {
        case .link: "Type these in Founderizer"
        case .setup: "Setting up this Mac"
        case .automaticLogin: "Turn on automatic login"
        case .lockScreen: "Set the Lock Screen to Never"
        case .claude: "Sign in to Claude"
        case .appleEvents: "Allow JavaScript from Apple Events"
        case .chatGPT: "Sign in to ChatGPT"
        case .computerUse: "Allow Computer Use"
        case .finish: "Unplug the monitor"
        case .checking: "Checking this Mac"
        case .nothingMissing: "Nothing is missing"
        }
    }

    /// The line under the title, nil when the title says it all.
    public var line: String? {
        switch self {
        case .link, .setup, .checking, .nothingMissing: nil
        case .automaticLogin: "So your agents come back after a restart."
        case .lockScreen: "Require a password after the screen turns off: Never."
        case .claude: "In Chrome, with the account made for this Mac."
        // Chrome keeps this menu item for each profile, and takes it only from this Mac's own hands (Chromium's
        // browser_commands_mac.mm refuses an event of another process): on the fleet's Mac Studio the agent's profile
        // had no tick, and neither Screen Sharing nor Computer Use could give it one (20 November 2026). The vault checks
        // the active tab of each window, so each profile with a window needs the tick, and once: the item is a switch, and
        // a second press in another window of the same profile takes the tick away. Three lines of the small window at
        // most, so that a stop's two lines and Try again still fit it.
        case .appleEvents: "Once in each open Chrome profile, with this Mac's own mouse (not Screen Sharing or Computer Use): "
            + "View, Developer."
        case .chatGPT: "For computer use."
        case .computerUse: "In the window that opened. Skip Chrome Extension."
        case .finish: "This Mac restarts by itself."
        }
    }

    /// The page's one button, nil where there is nothing to press.
    public var action: String? {
        switch self {
        case .link, .setup, .appleEvents, .computerUse, .checking: nil
        case .automaticLogin, .lockScreen: "Open Settings"
        case .claude: "Open Chrome"
        case .chatGPT: "Open ChatGPT"
        case .finish: "Finish"
        case .nothingMissing: "Done"
        }
    }

    /// macOS hides what the owner set here from every other app, so he says when he is done.
    public var hasNext: Bool { self == .lockScreen || self == .computerUse }

    /// The real logo over the title: the app that the page is about.
    public enum Logo: Sendable { case systemSettings, claude, chrome, chatGPT }

    public var logo: Logo? {
        switch self {
        case .automaticLogin, .lockScreen: .systemSettings
        case .claude: .claude
        case .appleEvents: .chrome
        case .chatGPT, .computerUse: .chatGPT
        case .link, .setup, .finish, .checking, .nothingMissing: nil
        }
    }

    /// The page shows no mark at all: its title and its spinner or buttons say it all.
    public var hasNoMark: Bool { self == .checking || self == .nothingMissing }

    /// The mark over the title of a page with no logo.
    public var symbol: String {
        switch self {
        case .link: "link"
        case .finish: "checkmark"
        default: "desktopcomputer"
        }
    }

    /// The System Settings page this step opens.
    public var settings: URL? {
        switch self {
        case .automaticLogin: URL(string: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension")
        case .lockScreen: URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")
        default: nil
        }
    }

    /// The line of this page on a Mac with FileVault on, which does not restart by itself.
    public func line(fileVault: Bool) -> String? {
        self == .finish && fileVault ? nil : line
    }

    /// The page after this one. A Mac with FileVault on has no automatic login: macOS offers none, so that page goes.
    public func next(fileVault: Bool, plan: MacSittingPlan = .both) -> MacSittingPage? {
        let all = plan.pages(fileVault: fileVault)
        guard let at = all.firstIndex(of: self), at + 1 < all.count else { return nil }
        return all[at + 1]
    }

    /// The page that Back goes to. The way back ends at the first page after the join: the join does not run twice.
    public func previous(fileVault: Bool, plan: MacSittingPlan = .both) -> MacSittingPage? {
        let all = plan.pages(fileVault: fileVault)
        guard let at = all.firstIndex(of: self), at > 0 else { return nil }
        let before = all[at - 1]
        return before == .link || before == .setup ? nil : before
    }

    /// The pages of the sitting proper. The link code and the root step come first, in the window's full size.
    public var isSmallWindow: Bool { self != .link && self != .setup }
}

/// **Which pages a sitting has**: only what the owner's choice of AI needs (the owner, 1 November 2026). The hub keeps
/// that choice, and the installer reads it at each start.
public struct MacSittingPlan: Equatable, Sendable {
    public let claude: Bool
    public let chatGPT: Bool

    public init(claude: Bool, chatGPT: Bool) { self.claude = claude; self.chatGPT = chatGPT }

    public static let both = MacSittingPlan(claude: true, chatGPT: true)

    public func pages(fileVault: Bool) -> [MacSittingPage] {
        (fileVault ? [.link, .setup, .lockScreen] : [.link, .setup, .automaticLogin, .lockScreen])
            + (claude ? [.claude, .appleEvents] : [])
            + (chatGPT ? [.chatGPT, .computerUse] : [])
            + (claude ? [] : [.appleEvents])
            + [.finish]
    }
}

/// **The parts of the root step**, by the word that `setup.sh` writes as each one begins, in the order that it runs
/// them: the setup page's bar has one segment for each (the owner's yes of 4 November 2026, "Steps bar"). A part that
/// this Mac has already writes no word, so the bar goes past it.
public enum MacSetupParts {
    public static let words = ["Developer tools", "Homebrew", "Tools", "Chrome", "ChatGPT", "Tailscale", "Your fleet",
                               "This Mac's settings"]

    /// How many parts have ended at this word of the step: a part ends when a later one begins, and the step's empty
    /// word at its end says that all of them have. Nil before its first word, and for a word that no part writes.
    public static func ended(at word: String?) -> Int? {
        guard let word else { return nil }
        return word.isEmpty ? words.count : words.firstIndex(of: word)
    }
}

/// What the hub answers about this Mac (`server.py needs`).
public struct MacNeeds: Decodable, Equatable, Sendable {
    public let status: Int?
    /// A runtime that works in Chrome: Claude's sign-in and its extension.
    public let browser: Bool?
    public let chatgpt: Bool?
    /// An agent's runtime is the ChatGPT app's own, so the agent's copy must be there beside the app's.
    public let own_copy: Bool?
    /// The state of its sitting, nil for a Mac that never had one.
    public let state: String?
    /// A screen task runs now, so the installer takes no screenshot of its own.
    public let screen_task: Bool?
    /// Its last reading found the screen locked.
    public let locked: Bool?

    public var plan: MacSittingPlan { MacSittingPlan(claude: browser == true, chatGPT: chatgpt == true) }

    /// A sitting runs: a first one, whatever file this Mac keeps.
    public var inSitting: Bool { state == "add" || state == "waiting" }

    public enum Reading: Equatable, Sendable {
        case needs(MacNeeds)
        /// A hub that knows this Mac no more: the installer goes back to its link code.
        case left
        /// A hub from before this route: the sitting has both.
        case older
        /// Nothing could be read, which never means that nothing is missing.
        case unread
    }

    public static func read(_ output: String) -> Reading {
        if output.contains("invalid choice") { return .older }      // a service that does not know this command yet
        guard let line = output.split(separator: "\n").last,
              let needs = try? JSONDecoder().decode(MacNeeds.self, from: Data(line.utf8)) else { return .unread }
        switch needs.status {
        case 200: return needs.browser == nil ? .unread : .needs(needs)
        case 403: return .left
        case 404: return .older
        default: return .unread
        }
    }
}

/// This Mac's own reading of Chrome and Claude's extension (`server.py desktop`, lifecycle's `Lifecycle.desktop`).
public struct MacDesktop: Decodable, Equatable, Sendable {
    /// Claude's extension in Chrome: on, off, or null where no profile has it or macOS hides Chrome's folder.
    public let `extension`: Bool?
    /// Chrome answers Claude Code's account. Read only while Claude Code is signed in and the extension is on or hidden.
    public let browser: Bool?
    /// macOS refuses this Mac's programs a list of Chrome's folder (macOS 27; lifecycle's `chrome_hidden`), so
    /// `extension` is null whether Chrome has the extension or not. Null from a `server.py` before it.
    public let hidden: Bool?
    /// The account and the organization of Claude Code on this Mac, which the extension must be signed in to (owner
    /// API 1.238). Null while Claude Code is signed out.
    public let claude_account: ClaudeAccount?
    /// What stops a sign-in of this Mac's Fleet Vault in Chrome now, the vault's own quiet word for the active tab of
    /// each Chrome window (owner API 1.271): `ok` alone means nothing does. Null with no vault, a busy one, or a
    /// `server.py` or a vault before that version.
    public let vault_chrome: String?

    public struct ClaudeAccount: Decodable, Equatable, Sendable {
        public let email: String
        public let org: String?
    }

    private enum Keys: String, CodingKey { case `extension`, browser, hidden, claude_account, vault_chrome }

    /// A `hidden` or an account of another shape reads as none: it never costs the reading of the extension and the link.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        self.extension = try values.decodeIfPresent(Bool.self, forKey: .extension)
        browser = try values.decodeIfPresent(Bool.self, forKey: .browser)
        hidden = try? values.decodeIfPresent(Bool.self, forKey: .hidden)
        claude_account = try? values.decodeIfPresent(ClaudeAccount.self, forKey: .claude_account)
        vault_chrome = try? values.decodeIfPresent(String.self, forKey: .vault_chrome)
    }

    /// A later opening leads the Apple Events page for a Mac with a vault, unless the vault's own quiet word is `ok`:
    /// any other word, none, or no reading (the page's own check then goes on at once where the script runs).
    public static func appleEventsMissing(vault: Bool, _ desktop: MacDesktop?) -> Bool {
        vault && desktop?.vault_chrome != "ok"
    }

    /// The command's last line, as `MacNeeds` reads its own. Nil for an answer that is not this reading.
    public static func read(_ output: String) -> MacDesktop? {
        output.split(separator: "\n").last.flatMap { try? JSONDecoder().decode(MacDesktop.self, from: Data($0.utf8)) }
    }

    /// Claude Code's sign-in comes after the extension: one that is on, or one that macOS hides, which no reading can
    /// say is on. Without the hidden one, a sitting on macOS 27 never started Claude Code's sign-in.
    public var extensionReady: Bool { self.extension == true || hidden == true }

    /// The Claude page's orange line when this Mac's Chrome opens no test page. It names the account and the
    /// organization of Claude Code here, which the extension must use (the owner, 19 November 2026: "the step 1 should
    /// mention the specific email address to use!"). Before, it said "the account made for this Mac".
    public static func noAnswer(_ desktop: MacDesktop?) -> String {
        var who = ", with the account made for this Mac."
        if let account = desktop?.claude_account {
            who = " as \(account.email)" + (account.org.map { ", organization \($0)" } ?? "")
            if !who.hasSuffix(".") { who += "." }       // an organization such as "Example Inc." ends the sentence
        }
        // The steps of the hub's card for such a Mac (hub.unlinked_steps) have this too: the line is the step, and the
        // installer cannot see whether Chrome has the extension there.
        return "This Mac's Chrome did not open the test page. Check that Claude's extension is logged in here" + who
            + (desktop?.hidden == true ? " If Chrome has no Claude extension, add it from the Chrome Web Store first." : "")
    }
}

/// **The vault's own check of Chrome**, for the page Allow JavaScript from Apple Events: `server.py chrome-script`, the
/// `chrome` answer of this Mac's Fleet Vault (owner API 1.271). Chrome keeps that menu item for each profile, and the
/// vault runs its one harmless script in the active tab of each Chrome window (the area Vault, keys and access, 20
/// November 2026; before, of the front window only), so its answer is `ok` only when each profile with a window has the
/// tick: the page's line asks for it once in each. Until that day the page read the `Preferences` file of every
/// profile, which macOS 27 can hide: a first sitting went on when any one had the tick and the vault's script ran in
/// the front window, and a later opening left the page out when any one had it. On the fleet's Mac Studio another
/// profile had it and the agent's had none, and every sign-in of its vault failed.
public enum MacVaultChrome: Equatable, Sendable {
    /// The script ran: the page goes on.
    case ok
    /// A step of the person at this Mac: no tick in the profile in front (`javascript_off`), no window (`no_window`), or
    /// macOS's question not answered yet (`not_asked`). The page's line says what to do.
    case waiting(String)
    /// macOS does not let Fleet Vault control Chrome: only System Settings changes that, and macOS never asks again.
    case refused
    /// A word that no step of the person answers: Chrome does not run (`not_running`), the vault starts (`launching`),
    /// an error of Chrome or macOS (`error`, with its number where one came), or a word of a later vault.
    case unclear(String, number: Int?)
    /// An answer with no word: a vault before 1.271, whose `ok` alone says whether the script ran, a vault that refused
    /// the quiet check, or a `server.py` before `--quiet`.
    case older
    /// No answer at all: no vault's socket, a vault that did not answer in time, or a command that failed before it.
    case silent

    /// The command's output: the vault's one line of JSON, which may follow a line of the shell; a traceback is none.
    public static func read(_ output: String) -> MacVaultChrome {
        for line in output.split(separator: "\n").reversed() {
            guard let answer = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            guard let cause = answer["cause"] as? String else { return answer["ok"] as? Bool == true ? .ok : .older }
            switch cause {
            case "ok": return .ok
            case "javascript_off", "no_window", "not_asked": return .waiting(cause)
            case "refused": return .refused
            default: return .unclear(cause, number: (answer["number"] as? NSNumber)?.intValue)
            }
        }
        return output.contains("unrecognized arguments") ? .older : .silent
    }

    /// The page's orange line when this answer stops it: at most two lines of the small window, with the next step.
    public var stop: String {
        switch self {
        case .refused: "In System Settings, Privacy & Security, Automation: allow Fleet Vault for Chrome."
        case .unclear("not_running", _): "Chrome does not run. Open Chrome, then Try again."
        case .unclear("launching", _): "Fleet Vault is still starting. Try again in a minute."
        case .unclear(_, let number?): "Chrome did not take the vault's script (error \(number)). Quit Chrome and open it again."
        case .silent: "Fleet Vault did not answer. Try again, or restart this Mac."
        // An older vault says no more than that its script did not run: no tick, or macOS's refusal.
        case .older: "Check the tick, and allow Fleet Vault in Privacy & Security, Automation."
        case .ok, .waiting, .unclear: "Chrome did not take the vault's script. Quit Chrome and open it again."
        }
    }
}

/// **The Apple Events page's checks**, one after another, two seconds apart, and what the page does after each.
/// The first check is not quiet: it starts a Chrome that does not run, and macOS asks its one question for the vault
/// at once, with a person here, because the vault's later sign-ins have nobody to answer it. The checks after it are
/// quiet (`--quiet`): they show nothing, start nothing and wait for no window, so they keep the vault's one queue of
/// jobs free for the agents' sign-ins (the reviews of 20 November 2026). A check is not quiet again while no check got
/// as far as macOS's question (Chrome did not run, the vault was starting or gave no answer), after an answer that
/// macOS has not asked it (`not_asked`), and after an answer with no word (an older vault or `server.py`), which only
/// a check that is not quiet answers.
public struct MacAppleEventsWatch: Equatable, Sendable {
    /// Whether the next check is not quiet (`server.py chrome-script`, with no `--quiet`).
    public private(set) var loud = true
    /// A check that was not quiet got as far as macOS's question: asked once, it is never asked again.
    private var asked = false
    private var older = false
    /// Checks in a row with no word that a step of the person answers.
    private var unclear = 0
    /// The most of those before the page stops: about half a minute.
    public static let most = 15
    /// Checks in a row whose answer has no word, and the most of them: about three minutes, as the person may still be
    /// in Chrome's menu.
    private var olderInRow = 0
    public static let olderMost = 90

    public enum Step: Equatable, Sendable {
        case next, wait
        case stop(String)
    }

    public init() {}

    public mutating func take(_ read: MacVaultChrome) -> Step {
        if loud {
            switch read {
            case .unclear("not_running", _), .unclear("launching", _), .older, .silent: break
            default: asked = true
            }
        }
        if read == .waiting("not_asked") { asked = false }      // the next check asks macOS again
        if read == .older { older = true }
        defer { loud = older || !asked }
        olderInRow = read == .older ? olderInRow + 1 : 0
        switch read {
        case .ok: return .next
        case .refused: return .stop(read.stop)
        case .waiting:
            unclear = 0
            return .wait
        case .older:
            unclear = 0
            return olderInRow >= Self.olderMost ? .stop(read.stop) : .wait
        case .unclear, .silent:
            unclear += 1
            return unclear >= Self.most ? .stop(read.stop) : .wait
        }
    }
}

/// What the installer keeps on that Mac between two starts: the page it stands on, so that a power cut does not lose
/// the owner's place, and the name of the root step it started. It holds no secret: the order stays in memory, and an
/// install stopped before the join starts again from a new link code.
public struct MacSittingRecord: Codable, Equatable, Sendable {
    public var page: MacSittingPage
    public var run: String?

    public init(page: MacSittingPage, run: String? = nil) { self.page = page; self.run = run }

    public static func read(_ url: URL) -> MacSittingRecord? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(MacSittingRecord.self, from: $0) }
    }

    public func write(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// What the commands of that Mac answer, read in one place so that a test can give each answer.
public enum MacSittingRead {
    /// `fdesetup status`.
    public static func fileVaultOn(_ output: String) -> Bool { output.contains("FileVault is On") }

    /// `defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser`.
    public static func automaticLogin(_ output: String, user: String) -> Bool {
        output.trimmingCharacters(in: .whitespacesAndNewlines) == user
    }

    /// `claude auth status`: the runtime's own JSON.
    public static func claudeSignedIn(_ output: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])?["loggedIn"] as? Bool == true
    }

    /// `codex login status`, which the ChatGPT app carries.
    public static func chatGPTSignedIn(_ output: String) -> Bool {
        output.contains("Logged in") && !output.contains("Not logged in")
    }

    /// What stopped the root step, in the owner's words: the last stop in its log. The script's line for a join that
    /// failed says less than the join's own stop before it.
    public static func stopped(_ log: String) -> String {
        let joinMarks = InstallPlan.stopMarks.map { $0 + " " }, setup = "Founderizer setup stopped: "
        var generic: String?
        for line in log.split(separator: "\n").reversed() {
            if let found = joinMarks.lazy.compactMap({ line.range(of: $0) }).first { return String(line[found.upperBound...]) }
            if let found = line.range(of: setup) {
                let said = String(line[found.upperBound...])
                guard said == noJoin else { return said }
                generic = generic ?? said
            }
        }
        return generic ?? "The setup stopped."
    }

    /// The script's own line when the hub's join line ended with no stop of its own.
    static let noJoin = "This Mac did not join your fleet."

    /// `exit` of the root step: its status when this is the run it names, else nil.
    public static func status(_ exit: String, run: String) -> Int? {
        let parts = exit.split(separator: " ")
        return parts.count == 2 && parts[0] == run ? Int(parts[1]) : nil
    }
}
