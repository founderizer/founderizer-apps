import Foundation
import Testing
@testable import FleetCore

/// **The row of a runtime's error in a task's thread** (`RuntimeErrorLine`; the owner's "Yes, build it" of 18 November
/// 2026): plain words in the place of the provider's own, and "is signed out" with its sign-in only while that is true
/// now.
@Suite struct RuntimeErrorWordsTests {
    /// The provider's own words of the error that the owner read on a paused screen task.
    private static let said = "workspace routing discovery unauthorized (401)"

    private func error(code: String? = "other", message: String? = RuntimeErrorWordsTests.said, id: Int = 4, attempt: Int = 1,
                       type: String = "error", parent: String? = nil) throws -> RuntimeEvent {
        var fields: [String: Any] = ["id": id, "attempt": attempt, "session": "s", "seq": id, "type": type]
        if let code { fields["code"] = code }
        if let message { fields["message"] = message }
        if let parent { fields["parent"] = parent }
        return try JSONDecoder().decode(RuntimeEvent.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    /// The server "box" of an agent on Claude Code, which is signed in there, with what the server says of Codex.
    private func machine(codex: Bool?, reported: Double = 1_000, stale: Bool = false, runtimes: Bool = true) throws -> MachineStatus {
        let other = codex.map { "\($0)" } ?? "null"
        let both = runtimes ? """
        {"claude": {"version": "2.1.287", "signed_in": true}, "codex": {"version": "0.166.0", "signed_in": \(other)}}
        """ : "null"
        return try JSONDecoder().decode(MachineStatus.self, from: Data("""
        {"agent": "solo", "machine": "box", "role": "worker", "address": "100.64.0.9", "access": null,
         "revision": null, "update": {"state": null, "detail": null, "requested_at": null, "finished_at": null},
         "check": null, "security": {}, "runtime": {"name": "claude", "version": "2.1.287", "signed_in": true},
         "os": {"name": null, "kernel": null}, "reported_at": \(reported), "stale": \(stale), "features": [],
         "models": null, "screen_models": null, "settings": null, "settings_pending": null, "verify": null,
         "runtimes": \(both), "login": null}
        """.utf8))
    }

    private func line(_ machine: MachineStatus?, last: Bool = true, runtimes: Set<String> = ["codex"],
                      error: RuntimeEvent? = nil) throws -> RuntimeErrorLine {
        RuntimeErrorLine(error: try error ?? self.error(), runtimes: runtimes, machine: machine, standsLast: last, time: 1_060)
    }

    /// The error that an open task's thread stops at says that the provider of its attempt is signed out on the agent's
    /// server, with the sign-in of THAT provider, only while a current reading of the server says so. Fails when the row
    /// reads the agent's own provider (signed in here) in the place of the session's, or says "is signed out" from an old
    /// reading, from a provider whose sign-in the server does not know, or on an error that is a record: the owner would
    /// then sign in a provider that works.
    @Test func theErrorThatTheThreadStopsAtSaysSignedOutOnlyWhileTheServersReadingSaysSo() throws {
        let out = try line(machine(codex: false))
        #expect(out == RuntimeErrorLine(says: "Codex is signed out on box", raw: Self.said, signIn: "codex", stands: true))
        let plain = RuntimeErrorLine(says: "Codex reported an error", raw: Self.said, signIn: nil, stands: true)
        #expect(try line(machine(codex: true)) == plain)
        #expect(try line(machine(codex: nil)) == plain)
        // An error that the thread does not stop at is a record: no "is signed out", and grey.
        #expect(try line(machine(codex: false), last: false)
                == RuntimeErrorLine(says: "Codex reported an error", raw: Self.said, signIn: nil, stands: false))
        #expect(try line(machine(codex: false, reported: 100)) == plain)
        #expect(try line(machine(codex: false, stale: true)) == plain)
        #expect(try line(nil) == plain)
        // An attempt on the agent's own provider, which the server says is signed in.
        #expect(try line(machine(codex: false), runtimes: ["claude"])
                == RuntimeErrorLine(says: "Claude Code reported an error", raw: Self.said, signIn: nil, stands: true))
        // The own provider of an agent on a local model signs in nowhere: its server's "not signed in" is no sign-out.
        // Codex of its screen tasks does sign in.
        let local = try machine(codex: false)
        #expect(RuntimeErrorLine(error: try error(), runtimes: ["codex"], machine: local, standsLast: true, time: 1_060,
                                 own: "codex", localModel: true) == plain)
        #expect(RuntimeErrorLine(error: try error(), runtimes: ["codex"], machine: local, standsLast: true, time: 1_060,
                                 own: "claude", localModel: true) == out)
        // A server that names only its own provider: that one's word counts, and Codex is not known there.
        #expect(try !machine(codex: false, runtimes: false).signedOut("codex"))
        #expect(try !machine(codex: false, runtimes: false).signedOut("claude"))
    }

    /// A usage limit keeps its own words, and so does an error of an attempt whose provider the record does not name
    /// or names two times: the row names no provider that it does not know. Fails when a usage limit, whose words are
    /// plain and whose state the task's mark says, becomes "reported an error" with a sign-in.
    @Test func aUsageLimitAndAnUnknownProviderKeepTheirOwnWords() throws {
        let limit = try error(code: "usage_limit", message: "Codex usage limit reached.")
        #expect(try line(machine(codex: false), error: limit)
                == RuntimeErrorLine(says: "Codex usage limit reached.", raw: nil, signIn: nil, stands: true))
        // A limit that holds the task no more is a record too.
        #expect(try !line(machine(codex: false), last: false, error: limit).stands)
        let own = RuntimeErrorLine(says: Self.said, raw: nil, signIn: nil, stands: true)
        #expect(try line(machine(codex: false), runtimes: []) == own)
        #expect(try line(machine(codex: false), runtimes: ["claude", "codex"]) == own)
        #expect(try line(machine(codex: false), runtimes: [], error: error(message: nil)).says == "Runtime error")
        // An error with no words of its provider has no words for the pointer.
        #expect(try line(machine(codex: false), error: error(message: "  ")).raw == nil)
    }

    /// The thread stops at an error only while no row of the thread's own level comes after it in that attempt. Fails
    /// when the error of a first attempt stays orange, or keeps "is signed out" with its link, while the next attempt
    /// works (the owner, 19 November 2026, after his sign-in: "that task still shows an orange error label, probably not
    /// updated"), or when a subagent's row or a subagent's error decides it.
    @Test func theThreadStopsAtAnErrorOnlyWhileNothingOfItsAttemptComesAfterIt() throws {
        var timeline = ActivityTimeline()
        timeline.append([try error(code: nil, message: "I look at the screen.", id: 1, type: "agent_message"),
                         try error(id: 2), try error(id: 3, parent: "call-1")])
        let (first, child) = (timeline.rows[1], timeline.rows[2])
        #expect(timeline.stands(first, attempt: 1))         // the child's row after it is not of the thread's own level
        #expect(!timeline.stands(child, attempt: 1))        // a subagent's error stops its own thread, not the task's
        #expect(!timeline.stands(first, attempt: 2))        // the task is in its next attempt
        timeline.append([try error(code: nil, message: "I go on.", id: 5, type: "agent_message")])
        #expect(!timeline.stands(first, attempt: 1))        // the session went on from it
    }

    /// The row of the usage limit that holds the task now is orange for that time, whatever its session wrote after
    /// the record. Fails when the limit's line is grey while the task waits for the limit (the hub asks a session at its
    /// limit for one more progress note, so a row can come after the record), or when the record of a limit that ended
    /// turns orange again at a later limit of the agent, or stays orange with no limit on the task.
    @Test func aUsageLimitStandsWhileItHoldsTheTask() throws {
        func holds(since: Double, task: Int?) throws -> RuntimeLimit {
            try JSONDecoder().decode(RuntimeLimit.self, from: JSONSerialization.data(withJSONObject:
                ["since": since, "until": since + 600, "reset_known": true, "task": task.map { $0 as Any } ?? NSNull()]))
        }
        func record(_ id: Int, at ts: Double) throws -> RuntimeEvent {
            try JSONDecoder().decode(RuntimeEvent.self, from: JSONSerialization.data(withJSONObject:
                ["id": id, "attempt": 1, "session": "s", "seq": id, "type": "error", "ts": ts, "code": "usage_limit",
                 "message": "Codex usage limit reached."]))
        }
        var timeline = ActivityTimeline()
        timeline.append([try record(1, at: 100), try error(code: nil, message: "I stop here.", id: 2, type: "agent_message"),
                         try record(3, at: 500), try error(code: nil, message: "My note of where I got to.", id: 4, type: "agent_message")])
        let (older, newest) = (timeline.rows[0], timeline.rows[2])
        // This task met the limit: the hub stored the record a moment after its own time, so the limit is younger.
        #expect(timeline.stands(newest, attempt: 1, limit: try holds(since: 503, task: 7), task: 7))
        #expect(!timeline.stands(older, attempt: 1, limit: try holds(since: 503, task: 7), task: 7))    // one line says it
        // A later limit of the agent, from another task or another agent of the account: this record is of a limit
        // that ended.
        #expect(!timeline.stands(newest, attempt: 1, limit: try holds(since: 900, task: 8), task: 7))
        #expect(!timeline.stands(newest, attempt: 1, limit: try holds(since: 900, task: nil), task: 7))
        // That limit also stopped this session, after it began.
        #expect(timeline.stands(newest, attempt: 1, limit: try holds(since: 480, task: 8), task: 7))
        #expect(!timeline.stands(newest, attempt: 2, limit: try holds(since: 503, task: 7), task: 7))   // an attempt before
        // No limit holds the task: it is over, or his hold comes first. Also when the record is the last row.
        #expect(!timeline.stands(newest, attempt: 1, task: 7))
        var last = ActivityTimeline()
        last.append([try record(1, at: 100)])
        #expect(!last.stands(last.rows[0], attempt: 1, task: 7))
    }
}
