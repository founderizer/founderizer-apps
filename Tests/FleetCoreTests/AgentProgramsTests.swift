import Foundation
import Testing
@testable import FleetCore

/// **Which of Claude Code and Codex are on this Mac** (`AgentPrograms`), the prompt that the welcome page copies
/// (`AgentPrompt`), and the welcome page's rules (`WelcomeRules`). Each test makes a scratch root and home of its own,
/// with stand-in files at the places, and reads them with the Mac's own disk.
struct AgentProgramsTests {
    /// A scratch "/" with a home folder in it.
    private final class Scratch {
        let root: URL
        var home: URL { root.appendingPathComponent("Users/example") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-programs-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Users/example"),
                                                    withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// A file at a path under the root, executable or not.
        func file(_ path: String, executable: Bool = true) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        }

        func folder(_ path: String) throws {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }

        func link(_ path: String, to target: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        }

        var found: Set<AgentPrograms.Program> { AgentPrograms.found(home: home, root: root) }
    }

    // MARK: each place

    @Test(arguments: ["Users/example/.local/bin/claude", "opt/homebrew/bin/claude", "usr/local/bin/claude",
                      "Users/example/.claude/local/claude", "Users/example/.local/share/claude/versions/2.1.312",
                      "Users/example/Library/Application Support/Claude/claude-code/2.1.321/ddbdf2b334e1/claude.app/Contents/MacOS/claude"])
    func claudeCodeIsFoundAtEachOfItsPlaces(_ place: String) throws {
        let scratch = try Scratch()
        try scratch.file(place)
        #expect(scratch.found == [.claudeCode])
    }

    @Test(arguments: ["Users/example/.local/bin/codex", "opt/homebrew/bin/codex", "usr/local/bin/codex"])
    func codexIsFoundAtEachOfItsPlaces(_ place: String) throws {
        let scratch = try Scratch()
        try scratch.file(place)
        #expect(scratch.found == [.codex])
    }

    @Test(arguments: ["Applications/Codex.app", "Users/example/Applications/Codex.app"])
    func theCodexDesktopAppCountsInEitherApplicationsFolder(_ place: String) throws {
        let scratch = try Scratch()
        try scratch.folder(place + "/Contents/MacOS")
        #expect(scratch.found == [.codex])
    }

    /// The native installer links `~/.local/bin/claude` to a version: the link counts as its target.
    @Test func aLinkToAVersionCounts() throws {
        let scratch = try Scratch()
        try scratch.file("Users/example/.local/share/claude/versions/2.1.312")
        try scratch.link("Users/example/.local/bin/claude",
                         to: scratch.home.appendingPathComponent(".local/share/claude/versions/2.1.312").path)
        try scratch.file("usr/local/bin/codex")
        #expect(scratch.found == [.claudeCode, .codex])
    }

    // MARK: the wrong kind of file, and none

    @Test func aFileOfTheWrongKindIsNoProgram() throws {
        let scratch = try Scratch()
        // A folder where a program belongs, a file that cannot run, and a link whose target is gone.
        try scratch.folder("Users/example/.local/bin/claude")
        try scratch.file("opt/homebrew/bin/claude", executable: false)
        try scratch.link("usr/local/bin/codex", to: "/nowhere/example/codex")
        // A versions folder with only a hidden file and a folder; the desktop copy's folder with no program in it.
        try scratch.file("Users/example/.local/share/claude/versions/.lock")
        try scratch.folder("Users/example/.local/share/claude/versions/2.1.300")
        try scratch.folder("Users/example/Library/Application Support/Claude/claude-code/2.1.321/ddbdf2b334e1/claude.app/Contents/MacOS")
        // A file named like the Codex app, and an app folder with no Contents.
        try scratch.file("Applications/Codex.app")
        try scratch.folder("Users/example/Applications/Codex.app")
        #expect(scratch.found.isEmpty)
    }

    @Test func aMacWithNeitherHasNone() throws {
        let scratch = try Scratch()
        #expect(scratch.found.isEmpty)
        #expect(AgentPrograms.names(scratch.found) == nil)
    }

    /// The disk is a value: a stand-in that answers every path with nothing finds nothing, and one that answers only
    /// Homebrew's Codex finds Codex alone. No real file is read.
    @Test func theDiskIsAValueThatATestReplaces() {
        let nothing = AgentPrograms.Disk(kind: { _ in .none }, names: { _ in [] })
        #expect(AgentPrograms.found(home: URL(fileURLWithPath: "/home-of-a-test"), disk: nothing).isEmpty)
        let homebrew = AgentPrograms.Disk(kind: { $0 == "/opt/homebrew/bin/codex" ? .file(executable: true) : .none },
                                          names: { _ in [] })
        #expect(AgentPrograms.found(home: URL(fileURLWithPath: "/home-of-a-test"), disk: homebrew) == [.codex])
    }

    // MARK: the words

    /// The words of the three sets of found programs, and of none, in English and in Spanish.
    @Test func theWordsNameWhatWasFoundInBothLanguages() throws {
        #expect(AgentPrograms.names([.claudeCode, .codex]) == "Claude Code or Codex")
        #expect(AgentPrograms.names([.claudeCode]) == "Claude Code")
        #expect(AgentPrograms.names([.codex]) == "Codex")
        #expect(AgentPrograms.names([]) == nil)
        #expect(AgentPrograms.wayTitle([.claudeCode, .codex]) == "Let Claude Code or Codex do it")
        #expect(AgentPrograms.wayTitle([.claudeCode]) == "Let Claude Code do it")
        #expect(AgentPrograms.wayTitle([.codex]) == "Let Codex do it")
        #expect(AgentPrograms.wayTitle([]) == nil)
        #expect(AgentPrograms.pasteTitle([.claudeCode, .codex]) == "Paste this in Claude Code or Codex")
        #expect(AgentPrograms.pasteTitle([.claudeCode]) == "Paste this in Claude Code")
        #expect(AgentPrograms.pasteTitle([.codex]) == "Paste this in Codex")
        #expect(AgentPrograms.pasteTitle([]) == "Paste this in Claude Code or Codex")
        let spanish = try LocalizedTests.table(Self.spanish())
        Localized.$bundle.withValue(spanish) {
            #expect(AgentPrograms.names([.claudeCode, .codex]) == "Claude Code o Codex")
            #expect(AgentPrograms.wayTitle([.claudeCode, .codex]) == "Deja que lo haga Claude Code o Codex")
            #expect(AgentPrograms.wayTitle([.claudeCode]) == "Deja que lo haga Claude Code")
            #expect(AgentPrograms.wayTitle([.codex]) == "Deja que lo haga Codex")
            #expect(AgentPrograms.wayTitle([]) == nil)
            #expect(AgentPrograms.pasteTitle([.claudeCode, .codex]) == "Pega esto en Claude Code o Codex")
            #expect(AgentPrograms.pasteTitle([.claudeCode]) == "Pega esto en Claude Code")
            #expect(AgentPrograms.pasteTitle([.codex]) == "Pega esto en Codex")
            #expect(AgentPrograms.pasteTitle([]) == "Pega esto en Claude Code o Codex")
        }
    }

    /// The table of the apps' words (`app/Localization/Localizable.xcstrings`), from this file's own place.
    private static func catalog() throws -> [String: Any] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Localization/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        return try #require(json?["strings"] as? [String: Any])
    }

    /// The keys of the welcome page and of the page after its press.
    private static let keys = ["Your own team of AI agents", "Set it up yourself", "Step by step", "Let %@ do it",
                               "Copy one prompt", "Paste this in %@", "Claude Code or Codex"]

    /// The Spanish of those keys, as the table has it.
    private static func spanish() throws -> [String: String] {
        let strings = try catalog()
        var words: [String: String] = [:]
        for key in keys {
            let entry = strings[key] as? [String: Any]
            let unit = ((entry?["localizations"] as? [String: Any])?["es"] as? [String: Any])?["stringUnit"] as? [String: Any]
            if let value = unit?["value"] as? String { words[key] = value }
        }
        return words
    }

    /// Each new key of the table has its Spanish, and the Spanish says "equipo" for the fleet, never "flota".
    @Test func eachNewKeyHasItsSpanish() throws {
        let words = try Self.spanish()
        for key in Self.keys {
            let value = try #require(words[key], "\(key) has no Spanish")
            #expect(!value.isEmpty && value != key || key == "Claude Code or Codex" && value == "Claude Code o Codex")
            #expect(!value.lowercased().contains("flota"))
        }
        #expect(words["Your own team of AI agents"] == "Tu propio equipo de agentes de IA")
    }

    // MARK: the prompt

    @Test func thePromptNamesTheGuidesAddressInBothLanguages() {
        let address = "https://founderizer.com/agent-install.md"
        #expect(AgentPrompt.english == "Install the Founderizer admin MCP, then guide me through my fleet setup. "
                + "Follow the instructions here: \(address)")
        #expect(AgentPrompt.spanish == "Instala el MCP de administración de Founderizer y guíame en la configuración de "
                + "mi equipo. Sigue las instrucciones de aquí: \(address)")
        #expect(AgentPrompt.english.hasSuffix(address) && AgentPrompt.spanish.hasSuffix(address))
        // Spanish says "equipo" for the fleet, never "flota".
        #expect(!AgentPrompt.spanish.contains("flota"))
        #expect(AgentPrompt.prompt(language: "es") == AgentPrompt.spanish)
        #expect(AgentPrompt.prompt(language: "es-MX") == AgentPrompt.spanish)
        #expect(AgentPrompt.prompt(language: "en") == AgentPrompt.english)
        #expect(AgentPrompt.prompt(language: "et") == AgentPrompt.english)
        #expect(AgentPrompt.prompt(language: nil) == AgentPrompt.english)
    }

    /// What is copied is the prompt in the language of the bundle that gives the app's words.
    @Test func theCopiedPromptFollowsTheBundlesLanguage() throws {
        #expect(AgentPrompt.shown == AgentPrompt.english)
        let spanish = try LocalizedTests.table(["Step by step": "Paso a paso"])
        Localized.$bundle.withValue(spanish) {
            #expect(AgentPrompt.shown == AgentPrompt.spanish)
        }
        #expect(AgentPrompt.shown == AgentPrompt.english)
    }

    /// The page shows the address on a line of its own; with that line break as a space again it is what is copied, and
    /// it holds no other line break and no invisible character.
    @Test func theShownPromptIsTheCopiedOneWithItsAddressOnALineOfItsOwn() {
        for prompt in [AgentPrompt.english, AgentPrompt.spanish] {
            let shown = AgentPrompt.lines(prompt)
            let lines = shown.split(separator: "\n", omittingEmptySubsequences: false)
            #expect(lines.count == 2)
            #expect(lines.last == "https://founderizer.com/agent-install.md")
            #expect(shown.replacingOccurrences(of: "\n", with: " ") == prompt)
            #expect(!prompt.contains("\n"))
            #expect(shown.unicodeScalars.allSatisfy { $0 == "\n" || $0.value >= 0x20 && !$0.properties.isDefaultIgnorableCodePoint })
            #expect(!shown.unicodeScalars.contains { [0x00A0, 0x2028, 0x2029].contains($0.value) })
        }
        #expect(AgentPrompt.lines("No address here") == "No address here")
    }

    // MARK: the welcome page's rules

    /// The notification of `founderizer-cli guide` takes the app only from the welcome page or the page after its press,
    /// and only while no connect runs. An install of this session that began and stopped does not stop it: back on
    /// these pages the wizard is at its start again.
    @Test func theGuideTakesTheAppOnlyFromTheFirstTwoPagesWithNoConnect() {
        #expect(WelcomeRules.guideTakesTheApp(on: .welcome, busy: false))
        #expect(WelcomeRules.guideTakesTheApp(on: .paste, busy: false))
        #expect(!WelcomeRules.guideTakesTheApp(on: .welcome, busy: true))
        #expect(!WelcomeRules.guideTakesTheApp(on: .paste, busy: true))
        #expect(!WelcomeRules.guideTakesTheApp(on: .cloud, busy: false))
        #expect(!WelcomeRules.guideTakesTheApp(on: .other, busy: false))
        #expect(WelcomeRules.atStart(.welcome) && WelcomeRules.atStart(.paste))
        #expect(!WelcomeRules.atStart(.cloud) && !WelcomeRules.atStart(.other))
    }

    @Test func backGoesToTheWelcomePage() {
        #expect(WelcomeRules.back(from: .paste) == .welcome)
        #expect(WelcomeRules.back(from: .cloud) == .welcome)
        #expect(WelcomeRules.back(from: .welcome) == nil)
        #expect(WelcomeRules.back(from: .other) == nil)
    }

    /// The first pages look for a fleet; after an install of this session began, the welcome page and the page after its
    /// press still do, and the VPS page does not, so it never connects to a hub that the install left half made.
    @Test func theFirstPagesLookForAFleetAndTheVPSPageNotAfterAnInstallBegan() {
        for page in [WelcomeRules.Page.welcome, .paste] {
            #expect(WelcomeRules.looksForAFleet(on: page, began: false, busy: false))
            #expect(WelcomeRules.looksForAFleet(on: page, began: true, busy: false))
            #expect(!WelcomeRules.looksForAFleet(on: page, began: false, busy: true))
        }
        #expect(WelcomeRules.looksForAFleet(on: .cloud, began: false, busy: false))
        #expect(!WelcomeRules.looksForAFleet(on: .cloud, began: true, busy: false))
        #expect(!WelcomeRules.looksForAFleet(on: .cloud, began: false, busy: true))
        #expect(!WelcomeRules.looksForAFleet(on: .other, began: false, busy: false))
    }

    // MARK: the welcome page of an unfinished setup

    /// With no fleet the first way is the first run's own next page; with a fleet whose setup never finished it is the
    /// manager's setup.
    @Test func theFirstWayGoesOnWhereTheSetupStands() {
        #expect(WelcomeRules.firstWay(fleet: false) == .firstRun)
        #expect(WelcomeRules.firstWay(fleet: true) == .managerSetup)
    }

    /// The welcome page of an unfinished setup looks for no fleet on any page: one is connected already.
    @Test func aConnectedFleetIsNeverLookedFor() {
        for page in [WelcomeRules.Page.welcome, .paste, .cloud, .other] {
            #expect(!WelcomeRules.looksForAFleet(on: page, began: false, busy: false, fleet: true))
        }
        // The guide's sign still takes the app from the two start pages: where it leads is `firstWay`.
        #expect(WelcomeRules.guideTakesTheApp(on: .welcome, busy: false))
        #expect(WelcomeRules.guideTakesTheApp(on: .paste, busy: false))
    }

    /// The welcome page stands in front of the manager's setup only when every condition holds, and each one alone
    /// takes it away: a first run of this start, a page that was passed, no program for the second way, a manager
    /// that has its server, another page than that setup, and work that runs.
    @Test func theWelcomePageCoversOnlyAnUnfinishedSetup() {
        func covers(hadFleet: Bool = true, passed: Bool = false, offersAgent: Bool = true, unplaced: Bool = true,
                    setupFills: Bool = true, runs: Bool = false) -> Bool {
            WelcomeRules.coversSetup(hadFleet: hadFleet, passed: passed, offersAgent: offersAgent, unplaced: unplaced,
                                     setupFills: setupFills, runs: runs)
        }
        #expect(covers())
        #expect(!covers(hadFleet: false))
        #expect(!covers(passed: true))
        #expect(!covers(offersAgent: false))
        #expect(!covers(unplaced: false))
        #expect(!covers(setupFills: false))
        #expect(!covers(runs: true))
    }

    /// The welcome page is passed when the owner leaves the manager's page: not by the page that the app itself opens
    /// on, not by a change from another page, and not by the same page again.
    @Test func leavingTheManagersPagePassesTheWelcomePage() {
        #expect(WelcomeRules.leaves(chosen: true, fromManager: true, changed: true))
        #expect(!WelcomeRules.leaves(chosen: false, fromManager: true, changed: true))
        #expect(!WelcomeRules.leaves(chosen: true, fromManager: false, changed: true))
        #expect(!WelcomeRules.leaves(chosen: true, fromManager: true, changed: false))
    }

    /// A new build goes in by itself on the welcome page and the VPS page at rest, never on the page after the press.
    @Test func thePageAfterThePressIsNeverAtRest() {
        #expect(WelcomeRules.atRest(on: .welcome, began: false, busy: false))
        #expect(WelcomeRules.atRest(on: .cloud, began: false, busy: false))
        #expect(!WelcomeRules.atRest(on: .paste, began: false, busy: false))
        #expect(!WelcomeRules.atRest(on: .other, began: false, busy: false))
        for page in [WelcomeRules.Page.welcome, .cloud] {
            #expect(!WelcomeRules.atRest(on: page, began: true, busy: false))
            #expect(!WelcomeRules.atRest(on: page, began: false, busy: true))
        }
    }
}
