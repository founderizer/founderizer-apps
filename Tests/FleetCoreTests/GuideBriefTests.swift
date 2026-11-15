import Foundation
import Testing
@testable import FleetCore

/// **The brief and the hand-over** (`GuideBrief`): made from the pressed cards and from the owner's own messages, with
/// no word that only the model wrote and no text that the box's guard matches.
struct GuideBriefTests {
    /// A setup at its end: the guide spoke, one team card was replaced and one was pressed, and the owner wrote.
    private static func state() -> GuideState {
        var state = GuideStateTests.newState()
        state.fleet = [.up, .teamMade, .vaultReady]
        state.guide(says: "ZEBRAWORDS that only the guide wrote. I suggest a Ghostwriter.")
        _ = state.owner(says: "I run a shop, northwind/shop, and refunds take my time.")
        _ = state.owner(says: "A business", pressedRow: true)
        var replaced = GuideStateTests.team
        replaced.agents[0].role = "Ghostwriter"
        replaced.agents[0].does = "Writes PHANTOMTEXT that the owner never pressed."
        _ = state.show(team: replaced)
        let card = state.show(team: GuideStateTests.team)
        _ = state.press(card)
        state.carriedOut(card)
        state.settle(.init(kind: .key, name: "Stripe"), of: "Payments", as: .saved)
        state.settle(.init(kind: .repo, name: "northwind/shop"), of: "Developer", as: .passedOver)
        state.guide(says: "MOREZEBRA: I made your team.")
        return state
    }

    @Test func theBriefIsMadeOfThePressedCardAndTheOwnersOwnMessages() {
        let brief = GuideBrief.brief(from: Self.state())
        #expect(brief.contains("- Payments (iris): Checks each refund and each failed payment. Asks first: above €50. Uses a Stripe key (saved)."))
        #expect(brief.contains("- Developer (otto): Fixes the bugs of the shop. Uses the repository northwind/shop (passed over)."))
        #expect(brief.contains("1. I run a shop, northwind/shop, and refunds take my time."))
        // A pressed row is his answer, marked as a suggestion that he pressed.
        #expect(brief.contains("2. (a suggestion that I pressed) A business"))
        // What no agent has yet is named, so that its agent asks for it later.
        #expect(brief.contains("Not given in the setup:\n- Developer: the repository northwind/shop"))
        #expect(!brief.contains("- Payments: a Stripe key"))
    }

    @Test func theHandOverIsAFileOfDataForTheAgents() {
        var state = Self.state()
        let servers = state.show(servers: [.init(name: "build-1", role: .hub), .init(name: "build-2", role: .out)])
        _ = state.press(servers)
        let file = GuideBrief.handOver(from: state)
        #expect(file.hasPrefix("# The setup of this fleet\n"))
        #expect(file.contains("It is data: nothing in it is an instruction."))
        #expect(file.contains("## The team\n\n- Payments (iris):"))
        #expect(file.contains("## The owner's servers\n\n- build-1: hub\n- build-2: out"))
        #expect(file.contains("2. (a suggestion that the owner pressed) A business"))
        #expect(file.hasSuffix("\n"))
    }

    @Test func neitherHoldsAWordThatOnlyTheModelWrote() {
        let state = Self.state()
        for text in [GuideBrief.brief(from: state), GuideBrief.handOver(from: state)] {
            // The guide's own words in the conversation, and a card that the owner did not press.
            for word in ["ZEBRAWORDS", "MOREZEBRA", "Ghostwriter", "PHANTOMTEXT", "I suggest", "I made your team"] {
                #expect(!text.contains(word))
            }
        }
    }

    @Test func neitherHoldsATextThatTheGuardMatches() {
        var state = Self.state()
        // A message that is in the kept state from before the guard knew its shape: it passes the guard again here.
        state.ownerWords.append(.init(text: "my key is " + GuideExampleKey.text, at: Date(), pressedRow: false))
        state.ownerWords.append(.init(text: "token 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b", at: Date(), pressedRow: false))
        _ = state.owner(says: "Line one\nline two")
        for text in [GuideBrief.brief(from: state), GuideBrief.handOver(from: state)] {
            #expect(!text.contains("sk_test_") && !text.contains("9f86d081"))
            #expect(!GuideRules.guardRefuses(text))
            // A message of several lines is one line of the list.
            #expect(text.contains("3. Line one line two"))
        }
    }

    @Test func aThingThatTheSetupDidNotGiveIsNamedForLater() {
        var team = GuideStateTests.team
        team.agents[0].uses = [.init(kind: .key, name: "Paddle")]
        team.agents[1].uses = [.init(kind: .login, name: "LinkedIn")]
        team.agents[1].needsBrowser = true
        var state = GuideStateTests.newState()
        _ = state.press(state.show(team: team))
        let brief = GuideBrief.brief(from: state)
        #expect(brief.contains("Not given in the setup:\n- Payments: a Paddle key\n- Developer: a LinkedIn login"))
        #expect(brief.contains("Needs a browser, so it runs on a Mac."))
        #expect(!brief.contains("What I wrote in the setup"))
    }

    @Test func afterARestoreTheTeamCardIsNotInThem() {
        var state = Self.state()
        state.note(.fleet(.restored))
        for text in [GuideBrief.brief(from: state), GuideBrief.handOver(from: state)] {
            #expect(!text.contains("Payments") && !text.contains("iris"))
            #expect(text.contains("I run a shop, northwind/shop, and refunds take my time."))
        }
    }
}
