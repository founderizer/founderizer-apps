import Foundation
import Testing
@testable import FleetCore

/// The pages of one sitting at a new Mac, and what the installer reads from that Mac's own commands.
struct MacSittingTests {
    @Test func thePagesComeInTheOrderTheOwnerApproved() {
        var order: [MacSittingPage] = [.link]
        while let next = order.last?.next(fileVault: false) { order.append(next) }
        #expect(order == [.link, .setup, .automaticLogin, .lockScreen, .claude, .appleEvents, .chatGPT, .computerUse, .finish])
    }

    @Test func aSittingHasOnlyWhatTheChoiceNeeds() {
        let tail: (MacSittingPlan) -> [MacSittingPage] = { Array($0.pages(fileVault: false).dropFirst(4)) }
        #expect(tail(.init(claude: true, chatGPT: false)) == [.claude, .appleEvents, .finish])
        #expect(tail(.init(claude: false, chatGPT: true)) == [.chatGPT, .computerUse, .appleEvents, .finish])
        #expect(tail(.both) == [.claude, .appleEvents, .chatGPT, .computerUse, .finish])
        #expect(MacSittingPage.lockScreen.next(fileVault: false, plan: .init(claude: false, chatGPT: true)) == .chatGPT)
        #expect(MacSittingPage.chatGPT.previous(fileVault: false, plan: .init(claude: false, chatGPT: true)) == .lockScreen)
        #expect(MacSittingPage.claude.next(fileVault: false, plan: .init(claude: true, chatGPT: false)) == .appleEvents)
    }

    @Test func aPageOutsideThePlanHasNoWayOn() {
        #expect(MacSittingPage.checking.next(fileVault: false) == nil)
        #expect(MacSittingPage.nothingMissing.previous(fileVault: false) == nil)
        #expect(MacSittingPage.finish.next(fileVault: false) == nil)
    }

    @Test func whatTheHubSaysIsReadWhole() {
        let line = "{\"agents\": [\"juno\"], \"browser\": true, \"chatgpt\": false, \"own_copy\": false, \"state\": \"done\", "
            + "\"screen_task\": false, \"locked\": false, \"status\": 200}\n"
        guard case .needs(let needs) = MacNeeds.read(line) else { Issue.record("not read"); return }
        #expect(needs.plan == MacSittingPlan(claude: true, chatGPT: false))
        #expect(!needs.inSitting)
        #expect(MacNeeds.read("{\"error\": \"no\", \"status\": 403}") == .left)
        #expect(MacNeeds.read("{\"status\": 404}") == .older)
        #expect(MacNeeds.read("server.py: error: argument cmd: invalid choice: 'needs'") == .older)
        #expect(MacNeeds.read("{\"status\": 500}") == .unread)
        #expect(MacNeeds.read("{\"status\": 200}") == .unread)         // an answer with nothing in it says nothing
        #expect(MacNeeds.read("") == .unread)
        #expect(MacNeeds.read("This machine has not joined your fleet.") == .unread)
    }

    @Test func aMacWithFileVaultOnHasNoAutomaticLoginPage() {
        #expect(MacSittingPage.setup.next(fileVault: true) == .lockScreen)
        #expect(MacSittingPage.setup.next(fileVault: false) == .automaticLogin)
    }

    @Test func onlyThePagesMacOSHidesHaveANextButton() {
        #expect(MacSittingPage.allCases.filter(\.hasNext) == [.lockScreen, .computerUse])
    }

    @Test func aPageThatOpensSettingsHasItsAddress() {
        for page in MacSittingPage.allCases {
            #expect((page.settings != nil) == (page.action == "Open Settings"), "\(page)")
        }
    }

    @Test func backEndsAtTheFirstPageAfterTheJoin() {
        #expect(MacSittingPage.claude.previous(fileVault: false) == .lockScreen)
        #expect(MacSittingPage.lockScreen.previous(fileVault: false) == .automaticLogin)
        #expect(MacSittingPage.automaticLogin.previous(fileVault: false) == nil)
        #expect(MacSittingPage.lockScreen.previous(fileVault: true) == nil)
        #expect(MacSittingPage.setup.previous(fileVault: false) == nil)
        #expect(MacSittingPage.link.previous(fileVault: false) == nil)
    }

    @Test func eachPageBackGoesToIsThePageBeforeIt() {
        for page in MacSittingPage.allCases {
            if let before = page.previous(fileVault: false) { #expect(before.next(fileVault: false) == page, "\(page)") }
        }
    }

    @Test func thePagesAboutAnAppShowItsLogo() {
        #expect(MacSittingPage.claude.logo == .claude)
        #expect(MacSittingPage.appleEvents.logo == .chrome)
        #expect(MacSittingPage.chatGPT.logo == .chatGPT)
        #expect(MacSittingPage.computerUse.logo == .chatGPT)
        #expect(MacSittingPage.allCases.filter { $0.logo == .systemSettings } == [.automaticLogin, .lockScreen])
        #expect(MacSittingPage.allCases.filter { $0.logo == nil } == [.link, .setup, .finish, .checking, .nothingMissing])
    }

    @Test func theRecordOfAPageHoldsThePageAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("sitting.json")
        #expect(MacSittingRecord.read(file) == nil)
        try MacSittingRecord(page: .claude).write(file)
        #expect(MacSittingRecord.read(file) == MacSittingRecord(page: .claude))
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self) == "{\"page\":\"claude\"}")
        try MacSittingRecord(page: .setup, run: "ab12").write(file)
        #expect(MacSittingRecord.read(file)?.run == "ab12")
    }

    @Test func eachCommandIsReadAsItAnswers() {
        #expect(MacSittingRead.fileVaultOn("FileVault is On.\n"))
        #expect(!MacSittingRead.fileVaultOn("FileVault is Off.\n"))
        #expect(MacSittingRead.automaticLogin("sam\n", user: "sam"))
        #expect(!MacSittingRead.automaticLogin("somebody\n", user: "sam"))
        #expect(!MacSittingRead.automaticLogin("", user: "sam"))
        #expect(MacSittingRead.claudeSignedIn("{\"loggedIn\": true}"))
        #expect(!MacSittingRead.claudeSignedIn("{\"loggedIn\": false}"))
        #expect(!MacSittingRead.claudeSignedIn("not json"))
        #expect(MacSittingRead.chatGPTSignedIn("Logged in using ChatGPT\n"))
        #expect(!MacSittingRead.chatGPTSignedIn("Not logged in\n"))
        #expect(MacSittingRead.appleEventsAllowed(Data("{\"browser\":{\"allow_javascript_apple_events\":true}}".utf8)))
        #expect(!MacSittingRead.appleEventsAllowed(Data("{\"browser\":{}}".utf8)))
        #expect(!MacSittingRead.appleEventsAllowed(Data("not json".utf8)))
    }

    @Test func theRootStepsEndIsReadForThisRunAlone() {
        #expect(MacSittingRead.status("ab12 0\n".trimmingCharacters(in: .newlines), run: "ab12") == 0)
        #expect(MacSittingRead.status("ab12 1", run: "ab12") == 1)
        #expect(MacSittingRead.status("cd34 0", run: "ab12") == nil)
        #expect(MacSittingRead.status("0", run: "ab12") == nil)
    }

    /// The setup page's bar has one segment for each part of the root step, in the order that the step runs them.
    @Test func theBarHasOneSegmentForEachPartInTheStepsOrder() throws {
        let script = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Installer/setup.sh"), encoding: .utf8)
        let lines = script.components(separatedBy: "\n")
        let quoted = { (line: String) in line.split(separator: "\"", omittingEmptySubsequences: false).dropFirst().first.map(String.init) }
        let body = { (part: String) -> [String] in      // the lines of the part's function
            guard let start = lines.firstIndex(where: { $0.hasPrefix(part + "() {") }) else { return [] }
            return Array(lines[start...].prefix { $0 != "}" })
        }
        var words: [String] = []
        for line in lines.drop(while: { !$0.hasPrefix("exec >>") }).dropFirst() {
            let call = String(line.split(separator: " ").first ?? "")
            let said = call == "app" || call == "word" ? quoted(line) : body(call).first { $0.contains("word \"") }.flatMap(quoted)
            if let said, !said.isEmpty, said != words.last { words.append(said) }
        }
        #expect(words == MacSetupParts.words)
    }

    @Test func theBarFillsUpToThePartThatRuns() {
        #expect(MacSetupParts.ended(at: nil) == nil)
        #expect(MacSetupParts.ended(at: "Developer tools") == 0)
        #expect(MacSetupParts.ended(at: "Your fleet") == 6)        // a run after a stop goes past the parts it has
        #expect(MacSetupParts.ended(at: "") == MacSetupParts.words.count)
        #expect(MacSetupParts.ended(at: "A word of no part") == nil)
    }

    @Test func aMacWithFileVaultOnIsNotToldItRestarts() {
        #expect(MacSittingPage.finish.line(fileVault: false)?.contains("restarts by itself") == true)
        #expect(MacSittingPage.finish.line(fileVault: true) == nil)
    }

    /// A login goes in the vault, and the agent asks for one when its work needs it: no page sends a person to a website.
    @Test func noPageAsksForAWebsiteSignIn() {
        for page in MacSittingPage.allCases {
            #expect(page.line?.localizedCaseInsensitiveContains("website") != true, "\(page)")
        }
    }

    @Test func aStopSaysTheLastStopLineOfTheLog() {
        #expect(MacSittingRead.stopped("one\nFounderizer setup stopped: Homebrew did not install.\n") == "Homebrew did not install.")
        #expect(MacSittingRead.stopped("Founderizer join stopped: The hub said no.\nthe join ended with a failure\n"
                                       + "Founderizer setup stopped: This Mac did not join your fleet.\n") == "The hub said no.")
        #expect(MacSittingRead.stopped("nothing here\n") == "The setup stopped.")
        #expect(MacSittingRead.stopped("Founderizer setup stopped: This Mac did not join your fleet.\n")
                == "This Mac did not join your fleet.")
        // A try that failed and a later stop: the later stop is what stands now.
        #expect(MacSittingRead.stopped("Founderizer join stopped: No hub.\nFounderizer setup stopped: Remote Login did not turn on.\n")
                == "Remote Login did not turn on.")
    }
}
