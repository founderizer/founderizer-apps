import Foundation
import Testing
@testable import FleetCore

// An agent's own lessons, beside its notes: the owner reads them and writes none, because they are the agent's words
// about its own work. The answer below is one the hub's own code gave (`memory_view`, 25 October 2026).

private func answer(_ body: String) throws -> OneAnswer { try OneAnswer(status: "200 OK") { _ in body } }

private func read(_ body: String, agent: String = "vps") async throws -> AgentMemory {
    let hub = try answer(body)
    return try await HubClient().memory(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db", agent: agent)
}

private let lessons = #"{"agent": "vps", "total": 4, "lessons": [{"id": 4, "kind": "lesson", "about": "the pool", "#
    + #""text": "Retire a signed-out account before the next run.", "prevents": "The same outage again", "#
    + #""at": 1789444000.0, "task": 16, "contradicted": 0, "contradicted_at": null, "stale": false, "held": 1, "#
    + #""held_until": 1797220000.0, "cost_minutes": null, "recheck": null}, {"id": 3, "kind": "dead_end", "#
    + #""about": "stripe", "text": "A test key cannot refund a live charge.", "#
    + #""prevents": "paying for this dead end a second time", "at": 1792896400.0, "task": 15, "contradicted": 0, "#
    + #""contradicted_at": null, "stale": false, "held": 0, "held_until": null, "cost_minutes": 180, "#
    + #""recheck": "One refund with the test key: a 400 says the wall stands."}, {"id": 2, "kind": "lesson", "#
    + #""about": "the shop", "text": "The deploy fails when the lock file is stale.", "#
    + #""prevents": "R-1 opening a case with the key 'deploy' again", "at": 1792468000.0, "task": 14, "#
    + #""contradicted": 1, "contradicted_at": 1792813600.0, "stale": false, "held": 0, "held_until": null, "#
    + #""cost_minutes": null, "recheck": null}, {"id": 1, "kind": "lesson", "about": "the pool", "#
    + #""text": "Check the signed-in pool count before reading any logs.", "prevents": "Twenty minutes in the logs", "#
    + #""at": 1786852000.0, "task": 12, "contradicted": 0, "contradicted_at": null, "stale": true, "held": 0, "#
    + #""held_until": null, "cost_minutes": null, "recheck": null}], "db": "db"}"#

@Test func theMemoryReadGivesTheLessonsThatStandWithTheHubsOwnEvidence() async throws {
    let hub = try answer(lessons)
    let memory = try await HubClient().memory(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db",
                                              agent: "vps")
    #expect(hub.received.starts(with: Data("GET /ui/memory/vps?db=db HTTP/1.1\r\n".utf8)))
    #expect(memory.agent == "vps" && memory.total == 4)
    #expect(memory.lessons.map(\.id) == [4, 3, 2, 1])
    let held = memory.lessons[0], wall = memory.lessons[1], keyed = memory.lessons[2], old = memory.lessons[3]
    #expect(held.kind == .lesson && held.about == "the pool" && held.task == 16 && held.at == 1789444000)
    #expect(held.held == 1 && held.held_until == 1797220000 && !held.stale)
    #expect(wall.kind == .deadEnd && wall.cost_minutes == 180)
    #expect(wall.recheck == "One refund with the test key: a 400 says the wall stands.")
    #expect(keyed.contradicted == 1 && keyed.contradicted_at == 1792813600 && keyed.held_until == nil)
    #expect(old.stale && old.prevents == "Twenty minutes in the logs" && old.cost_minutes == nil)
}

@Test func aMarkStandsOnlyWhereTheHubHasNews() async throws {
    let memory = try await read(lessons)
    #expect(memory.lessons[0].news.isEmpty)                         // borne out again, and nothing else to tell
    #expect(memory.lessons[1].news == [.deadEnd])
    #expect(memory.lessons[2].news == [.contradicted(1)])
    #expect(memory.lessons[3].news == [.stale])
    let aged = AgentMemory.Lesson(id: 9, kind: .deadEnd, about: "stripe", text: "x", contradicted: 3, stale: true)
    #expect(aged.news == [.deadEnd, .stale, .contradicted(3)])
    #expect(aged.news.map(\.words) == ["Dead end", "Stale", "Contradicted 3 times"])
    #expect(LessonNews.contradicted(1).words == "Contradicted")
}

@Test func aKindOrAMarkThisAppDoesNotKnowDecodesSafely() async throws {
    // A newer hub may add a kind, drop a mark or change its type: the list stays readable, and what the app cannot
    // read is no news rather than a failed page.
    let memory = try await read(#"{"db":"db","agent":"vps","total":3,"lessons":["#
        + #"{"id":3,"kind":"rule","about":"the fleet","text":"A kind from a newer hub.","stale":"maybe","#
        + #""contradicted":null,"surprise":{"new":true}},"#
        + #"{"id":2,"text":"Only the lesson itself."},"#
        + #"{"id":1,"kind":7,"about":"x","text":"A kind that is not text.","held":2}]}"#)
    #expect(memory.lessons.map(\.id) == [3, 2, 1])
    #expect(memory.lessons[0].kind == .other("rule") && memory.lessons[0].news.isEmpty)
    #expect(!memory.lessons[0].stale && memory.lessons[0].contradicted == 0)
    #expect(memory.lessons[1].kind == .lesson && memory.lessons[1].about.isEmpty && memory.lessons[1].at == nil)
    #expect(memory.lessons[2].kind == .other("") && memory.lessons[2].held == 2 && memory.lessons[2].news.isEmpty)
}

@Test func anAgentWithNoLessonsIsAnEmptyListAndNotAFailure() async throws {
    let memory = try await read(#"{"db":"db","agent":"vps","total":0,"lessons":[]}"#)
    #expect(memory.total == 0 && memory.lessons.isEmpty)
}

@Test func lessonsOfTheWrongGenerationOrAgentOrThatContradictThemselvesAreNotShown() async throws {
    // The hub answers its own generation and its own agent; a count under the list, a lesson twice and a lesson
    // with no text are not this reading either.
    for body in [#"{"db":"other","agent":"vps","total":0,"lessons":[]}"#,
                 #"{"db":"db","agent":"studio","total":0,"lessons":[]}"#,
                 #"{"db":"db","agent":"vps","total":0,"lessons":[{"id":1,"text":"x"}]}"#,
                 #"{"db":"db","agent":"vps","total":2,"lessons":[{"id":1,"text":"x"},{"id":1,"text":"y"}]}"#,
                 #"{"db":"db","agent":"vps","total":1,"lessons":[{"id":0,"text":"x"}]}"#,
                 #"{"db":"db","agent":"vps","total":1,"lessons":[{"id":1}]}"#] {
        await #expect(throws: (any Error).self) { try await read(body) }
    }
}

@Test func theMemoryRouteTakesOnlyAnAgentName() async throws {
    for name in ["", "VPS", "../state", "vps/notes", "9vps"] {
        await #expect(throws: (any Error).self) {
            try await HubClient().memory(hub: URL(string: "http://127.0.0.1:1")!, database: "db", agent: name)
        }
    }
}

@Test func aRefusalCarriesTheHubsOwnWords() async throws {
    let hub = try OneAnswer(status: "404 Not Found") { _ in #"{"error":"no such agent"}"# }
    do {
        _ = try await HubClient().memory(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db", agent: "vps")
        Issue.record("a refusal was read as lessons")
    } catch {
        #expect(HubError.said(error) == "no such agent")
    }
}

@Test func theLessonsAreOnlyOfferedByNameInTheFeatures() {
    // A hub from before 25 October 2026 answers 404, so the feature name is the only way the app learns the route.
    #expect(AgentMemory.feature == "agent_memory")
}
