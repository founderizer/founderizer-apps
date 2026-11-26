import Foundation
import Testing
@testable import FleetCore

/// **A task's page in the owner's words** (`StepWords`, `ModelWords`, `TaskFacts`; his "Yes, build it" of 17 November
/// 2026 to the pictures of the Task page): what a thread and its panel call a step, a child agent, a changed file and a
/// model, until when a task is parked, and whose words its request is.
@Suite struct StepWordsTests {
    private func event(_ fields: [String: Any]) throws -> RuntimeEvent {
        let base: [String: Any] = ["id": 1, "attempt": 1, "session": "s", "seq": 1, "type": "tool_call", "tool_call_id": "t1"]
        return try JSONDecoder().decode(RuntimeEvent.self, from: JSONSerialization.data(withJSONObject: base.merging(fields) { _, new in new }))
    }

    private static var hold: [String: Any] { ["since": 999_000.0, "until": 1_010_000.0, "reset_known": true, "task": NSNull()] }

    private func state(_ tasks: [[String: Any]], holds: [[String: Any]] = [], limited: Bool = false,
                       features: [String]? = nil) throws -> HubState {
        var agent: [String: Any] = ["name": "atlas", "role": "worker", "runtime": "claude", "can": []]
        if limited { agent["limit"] = Self.hold }
        var fields: [String: Any] = [
            "schema_version": 1, "db": "test-db", "time": 1_000_000.0, "agents": [agent], "tasks": tasks, "holds": holds,
            "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [], "reports": []]
        if let features { fields["ui_features"] = features }
        return try HubState.decode(JSONSerialization.data(withJSONObject: fields))
    }

    private func task(_ fields: [String: Any]) -> [String: Any] {
        ["id": 7, "title": "Pin the base image", "details": "Pin it.", "done_when": "Pinned.", "needs": "none", "goal": "",
         "owner": "atlas", "requester": "manager", "state": "working", "created": 1.0, "attempt": 1, "restarts": 0,
         "nudge_level": 0, "stop_sent": 0].merging(fields) { _, new in new }
    }

    /// The agent's own line wins over the command; with none, an edit or a command takes the hub's words for its kind
    /// and its file, never a machine path; a Fleet call and an MCP server's call keep their titles. Fails when `says` is
    /// not read from the hub's events (the thread showed four lines of a shell command), or when the title comes first.
    @Test func aStepIsTheAgentsOwnLineElseTheHubsWordsForItsKind() throws {
        let path = "/home/fleet-atlas/fleet-work/.tasks/atlas/0123456789ab/T-12/acme/api/src/scraper.py"
        #expect(StepWords.of(try event(["kind": "execute", "title": "Bash: S=/tmp/x; for i in $(seq 1 40); do kubectl logs; done",
                                         "says": "Capture the worker log"])) == "Capture the worker log")
        #expect(StepWords.of(try event(["kind": "edit", "title": "Edit: \(path)", "locations": [["path": path]]])) == "Editing scraper.py")
        #expect(StepWords.of(try event(["kind": "execute", "title": "Bash: ls"])) == "Running a command")
        #expect(StepWords.of(try event(["kind": "search", "title": "WebSearch: weather"])) == "Searching the web")
        #expect(StepWords.of(try event(["kind": "read", "title": "fleet: read_messages: T-1", "server": "fleet"])) == nil)
        #expect(StepWords.of(try event(["kind": "read", "title": "crm: find_contact", "server": "crm"])) == nil)
    }

    /// A search for tools is the runtime loading its own tools: no step and no words (a fold said "1 step" for one).
    @Test func aSearchForToolsIsNoStep() throws {
        #expect(StepWords.isToolSearch("ToolSearch: select:mcp__fleet__read_messages"))
        #expect(!StepWords.isToolSearch("Bash: grep ToolSearch session.log"))
        #expect(StepWords.of(try event(["kind": "search", "title": "ToolSearch: select:TaskCreate"])) == nil)
    }

    /// Two children of one task are told apart by what each was asked, not by their kind ("general-purpose").
    @Test func aChildAgentIsNamedByWhatItWasAsked() {
        #expect(StepWords.childTitle("Agent: Independent review of the diff") == "Independent review of the diff")
        #expect(StepWords.childTitle("Task: Re-check the fix") == "Re-check the fix")
        #expect(StepWords.childTitle("Bash: ls") == nil)
        #expect(StepWords.childTitle("Agent: ") == nil)
    }

    /// A changed file shows from its repository's root, in a task's own clone and in the shared one, and any other path
    /// stays whole. Fails when the task's folder (agent, generation, window) is taken for the repository.
    @Test func aChangedFileShowsFromItsRepositorysRoot() {
        let place = StepWords.inRepository("/home/fleet-atlas/fleet-work/.tasks/atlas/0123456789ab/T-12/acme/api/src/scrapers/x.py")
        #expect(place?.repository == "acme/api")
        #expect(place?.path == "src/scrapers/x.py")
        let shared = StepWords.inRepository("/home/fleet-atlas/fleet-work/acme/api/README.md")
        #expect(shared?.repository == "acme/api")
        #expect(shared?.path == "README.md")
        #expect(StepWords.inRepository("/home/fleet-atlas/notes/x.py") == nil)
        #expect(StepWords.inRepository("/home/fleet-atlas/fleet-work/.tasks/atlas/0123456789ab/T-12/acme") == nil)
    }

    /// A model shows by the name that its server's list gives its alias, with the id's version: a session reports
    /// "claude-opus-5-5" and the list names "opus", so an exact lookup showed the id. A suffix or a date at the end is no
    /// version, and an id that no alias matches stays whole.
    @Test func aModelShowsByItsProvidersName() throws {
        let options = try JSONDecoder().decode([RuntimeModels.Option].self, from: Data("""
            [{"model": "opus", "display_name": "Opus", "default": false, "efforts": []},
             {"model": "sonnet", "display_name": "Sonnet", "default": true, "efforts": []},
             {"model": "gpt-5.6-sol", "display_name": "GPT-5.6 Sol", "default": false, "efforts": []}]
            """.utf8))
        #expect(ModelWords.shown("claude-opus-5-5", options: options) == "Opus 5.5")
        #expect(ModelWords.shown("claude-opus-5-5[1m]", options: options) == "Opus 5.5")
        #expect(ModelWords.shown("claude-sonnet-4-5@20250929", options: options) == "Sonnet 4.5")
        #expect(ModelWords.shown("claude-sonnet-4-5-20250929", options: options) == "Sonnet 4.5")
        #expect(ModelWords.shown("gpt-5.6-sol", options: options) == "GPT-5.6 Sol")
        #expect(ModelWords.shown("claude-haiku-5-5", options: options) == "claude-haiku-5-5")
        #expect(ModelWords.shown("claude-opus-5-5", options: []) == "claude-opus-5-5")
    }

    /// The live line names the newest step of the attempt that has not ended and says something: a capture in the
    /// background still runs after later steps ended. Fails when the newest row is taken whatever its state, or a row
    /// of another attempt.
    @Test func theLiveLineTakesTheNewestStepThatStillRuns() throws {
        var timeline = ActivityTimeline()
        timeline.append([
            try event(["id": 1, "seq": 1, "tool_call_id": "old", "kind": "execute", "title": "Bash: a",
                       "says": "A step of the attempt before", "status": "in_progress"]),
            try event(["id": 2, "seq": 2, "attempt": 2, "tool_call_id": "capture", "kind": "execute", "title": "Bash: b",
                       "says": "Capture the worker log", "status": "in_progress"]),
            try event(["id": 3, "seq": 3, "attempt": 2, "tool_call_id": "count", "kind": "execute", "title": "Bash: c",
                       "says": "Count the sources", "status": "in_progress"]),
            try event(["id": 4, "seq": 4, "attempt": 2, "type": "tool_call_update", "tool_call_id": "count", "status": "completed"]),
            try event(["id": 5, "seq": 5, "attempt": 2, "tool_call_id": "note", "kind": "other", "title": "fleet: report_progress: T-9",
                       "server": "fleet", "status": "in_progress"]),
        ])
        #expect(StepWords.running(in: timeline, attempt: 2) == "Capture the worker log")
        #expect(StepWords.running(in: timeline, attempt: 3) == nil)
    }

    /// "Resumes at 02:30" only while nothing else holds the task: a hold of his that is not released and a usage limit
    /// that holds it (on a hub with `task_limit` its own `limit`, else its agent's) say their own words, and a hold that
    /// he released does not. The rule of an ask's row and of the task's panel; fails when the rule counts a released
    /// hold, says "Until" over a pause, or reads the agent's limit on a hub that gives the task its own.
    @Test func aParkedTaskSaysUntilOnlyWhileNothingElseHoldsIt() throws {
        let parked = task(["parked_until": 1_003_600.0])
        let hold: [String: Any] = ["id": 1, "task": 7, "kind": "pause", "state": "stopped", "attempt": 1]
        let free = try state([parked])
        #expect(free.tasks[0].parkedUntil(in: free) == 1_003_600.0)
        let paused = try state([parked], holds: [hold])
        #expect(paused.tasks[0].parkedUntil(in: paused) == nil)
        let released = try state([parked], holds: [hold.merging(["state": "released"]) { _, new in new }])
        #expect(released.tasks[0].parkedUntil(in: released) == 1_003_600.0)
        let limited = try state([parked], limited: true)
        #expect(limited.tasks[0].parkedUntil(in: limited) == nil)
        let ownHold = try state([task(["parked_until": 1_003_600.0, "limit": Self.hold])], features: [TaskLimit.feature])
        #expect(ownHold.tasks[0].parkedUntil(in: ownHold) == nil)
        let agentHold = try state([parked], limited: true, features: [TaskLimit.feature])
        #expect(agentHold.tasks[0].parkedUntil(in: agentHold) == 1_003_600.0)
        let over = try state([task(["parked_until": 1_003_600.0, "state": "completed"])])
        #expect(over.tasks[0].parkedUntil(in: over) == nil)
    }

    /// A result's page says its plain line at rest, and its whole result only behind Show more; a line that is the whole
    /// result again, or none, leaves the whole result at rest. Fails when the page shows the agent's report for its
    /// requester over a plain line, or the same words twice.
    @Test func aResultSaysItsPlainLineAtRest() throws {
        let whole = "Found the cause: the door (192.0.2.10:8766) is unreachable from box since 07:27 UTC."
        let plain = try state([task(["state": "completed", "what": whole, "plain": "The disk check is fine."])])
        #expect(plain.tasks[0].resultAtRest == "The disk check is fine.")
        let twice = try state([task(["state": "completed", "what": "Pinned  the image.\n", "plain": "Pinned the image."])])
        #expect(twice.tasks[0].resultAtRest == "Pinned  the image.\n")
        let none = try state([task(["state": "completed", "what": whole, "plain": " "])])
        #expect(none.tasks[0].resultAtRest == whole)
        #expect(try state([task([:])]).tasks[0].resultAtRest == nil)
    }

    /// What he asked an agent for in its chat is his own message, though the hub makes the manager or a lead its
    /// requester; any other request is its requester's. Fails when the thread draws his words under the Fleet
    /// Manager's name, or a brief that only quotes him as his own.
    @Test func whatHeAskedInAChatIsHisOwnWords() throws {
        let asked = try state([task(["details": "The owner asked for this in their own words, in atlas's chat: Pin the base image today."])])
        #expect(asked.tasks[0].ownersWords == "Pin the base image today.")
        let before = try state([task(["details": "The owner asked for this in his own words, in atlas's chat: Pin it."])])
        #expect(before.tasks[0].ownersWords == "Pin it.")
        let brief = try state([task(["details": "The owner's order (17 Nov): pin the base image."])])
        #expect(brief.tasks[0].ownersWords == nil)
    }
}
