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
        case .appleEvents: "In Chrome: View, Developer."
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

    /// One Chrome profile's `Preferences`: the menu item that Chromium takes only from a real keyboard or mouse.
    public static func appleEventsAllowed(_ preferences: Data) -> Bool {
        let object = try? JSONSerialization.jsonObject(with: preferences) as? [String: Any]
        return (object?["browser"] as? [String: Any])?["allow_javascript_apple_events"] as? Bool == true
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
