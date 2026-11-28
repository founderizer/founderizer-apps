import FleetCore
import Foundation
import Testing
@testable import Founderizer

/// **A person's chat-app ID comes only from the chat app** (the owner's "From 'Wrote and was not answered', with Add" of
/// 26 November 2026 to question 3 of `channels-2026-11-26`: "A typed number is only a claim"): no field of Add person or
/// of a channel's steps takes one, so neither may lead to a step that waits for one. On the main actor: the two rules are
/// statics of views, which are the main actor's, and a call from another thread is a trap of Swift's isolation check.
@MainActor struct SentHandleOnlyTests {
    private func person(_ handles: [[String: Any]]) throws -> PeopleSnapshot.Person {
        try JSONDecoder().decode(PeopleSnapshot.Person.self, from: JSONSerialization.data(withJSONObject: [
            "id": 12, "name": "Ana", "role": "customer", "added": 900.0,
            "agents": [["agent": "studio", "can_chat": true]], "handles": handles, "conversations": []]))
    }

    /// **Add person adds on its last step**: Where does Ana write from? only for a sender of Wrote and was not answered,
    /// whose ID it shows; with no sender, Who can Ana talk to?, or What is Ana to you? where the agent of the page left
    /// that step out. A person with no place who reached step five would stand on a page with nothing on it.
    @Test func addPersonAddsOnItsLastStepAndShowsStepFiveOnlyForASender() {
        #expect(AddPersonView.last(agent: nil, places: true) == .places)
        #expect(AddPersonView.last(agent: "studio", places: true) == .places)
        #expect(AddPersonView.last(agent: nil, places: false) == .agents)
        #expect(AddPersonView.last(agent: "studio", places: false) == .role)
    }

    /// **A tile of Who can write to <agent>? is a button only where a press can tick it**: a person with a number or an
    /// ID of this app gets the agent, and a tile that this visit ticked can be unticked. A person with none is no button:
    /// the press asked for their number on a page that is gone, and a press that gave only the agent would show no tick.
    @Test func aTileOfAPersonWithNoIDOfTheAppIsNoButton() throws {
        let none = try person([]), discord = try person([["app": "discord", "handle": "500600700"]])
        let whatsapp = try person([["app": "whatsapp", "handle": "34600111001@s.whatsapp.net"]])
        #expect(!ChannelFollowSteps.ticks(none, app: "whatsapp", on: false, mine: false))
        #expect(!ChannelFollowSteps.ticks(discord, app: "whatsapp", on: false, mine: false))
        #expect(ChannelFollowSteps.ticks(whatsapp, app: "whatsapp", on: false, mine: false))
        #expect(ChannelFollowSteps.ticks(whatsapp, app: "whatsapp", on: true, mine: true))
        // who could write here before these steps changes that on their own page
        #expect(!ChannelFollowSteps.ticks(whatsapp, app: "whatsapp", on: true, mine: false))
    }
}
