import Foundation
import Testing
@testable import FleetCore

// An agent's own working notes: the owner's window into how each agent actually operates. The app reads them and
// writes none of them, because the profile is his words and these are the agent's.

private func answer(_ body: String) throws -> OneAnswer { try OneAnswer(status: "200 OK") { _ in body } }

private let written = #"{"db":"db","agent":"vps","text":"Read the check first.","revision":2,"versions":["#
    + #"{"revision":2,"text":"Read the check first.","why":"the daily review","by":"vps","at":1000.5,"#
    + #""task":90,"duty_case":7},"#
    + #"{"revision":1,"text":"Start with the queue.","why":"first notes","by":"vps","at":900.0,"#
    + #""task":81,"duty_case":null}]}"#

@Test func theNotesReadGivesWhatStandsNowAndEveryVersionBeforeIt() async throws {
    let hub = try answer(written)
    let notes = try await HubClient().notes(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db", agent: "vps")
    #expect(hub.received.starts(with: Data("GET /ui/notes/vps?db=db HTTP/1.1\r\n".utf8)))
    #expect(notes.agent == "vps" && notes.revision == 2)
    #expect(notes.said == "Read the check first.")
    #expect(notes.versions.map(\.revision) == [2, 1])
    #expect(notes.earlier.map(\.revision) == [1])
    #expect(notes.versions.first?.why == "the daily review" && notes.versions.first?.task == 90)
    #expect(notes.versions.first?.duty_case == 7 && notes.versions.last?.duty_case == nil)
}

@Test func anAgentThatHasWrittenNoneSaysSoWithoutAnEmptyBlock() async throws {
    let hub = try answer(#"{"db":"db","agent":"vps","text":null,"revision":0,"versions":[]}"#)
    let notes = try await HubClient().notes(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db", agent: "vps")
    #expect(notes.revision == 0 && notes.versions.isEmpty && notes.said == nil && notes.earlier.isEmpty)
}

@Test func notesOfTheWrongGenerationOrAgentAreNotShown() async throws {
    // The hub answers its own generation and its own agent; anything else is not this reading.
    let wrongAgent = try answer(#"{"db":"db","agent":"studio","text":null,"revision":0,"versions":[]}"#)
    await #expect(throws: (any Error).self) {
        try await HubClient().notes(hub: URL(string: "http://127.0.0.1:\(wrongAgent.port)")!, database: "db", agent: "vps")
    }
    let wrongDatabase = try answer(#"{"db":"other","agent":"vps","text":null,"revision":0,"versions":[]}"#)
    await #expect(throws: (any Error).self) {
        try await HubClient().notes(hub: URL(string: "http://127.0.0.1:\(wrongDatabase.port)")!, database: "db", agent: "vps")
    }
}

@Test func notesThatContradictThemselvesAreRefused() async throws {
    // A revision with no version behind it, a text with no version, and a newest version that is not the one that
    // stands: each would show the owner words that no version accounts for.
    for body in [#"{"db":"db","agent":"vps","text":"x","revision":2,"versions":[]}"#,
                 #"{"db":"db","agent":"vps","text":null,"revision":0,"versions":[{"revision":1,"text":"x"}]}"#,
                 #"{"db":"db","agent":"vps","text":"x","revision":2,"versions":[{"revision":1,"text":"x"}]}"#,
                 #"{"db":"db","agent":"vps","text":"x","revision":1,"versions":[{"revision":1,"text":"x"},{"revision":1,"text":"y"}]}"#] {
        let hub = try answer(body)
        await #expect(throws: (any Error).self) {
            try await HubClient().notes(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db", agent: "vps")
        }
    }
}

@Test func theNotesRouteTakesOnlyAnAgentName() async throws {
    // Nothing is asked of the network for a name that cannot be one: the path would not be a notes path.
    for name in ["", "VPS", "../state", "vps/notes", "9vps"] {
        await #expect(throws: (any Error).self) {
            try await HubClient().notes(hub: URL(string: "http://127.0.0.1:1")!, database: "db", agent: name)
        }
    }
}

@Test func theNotesSectionIsOnlyOfferedByNameInTheFeatures() {
    // A hub from before 19 October 2026 answers 404, so the feature name is the only way the app learns the route.
    #expect(AgentNotes.feature == "agent_notes")
}
