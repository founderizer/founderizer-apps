import Testing

/// **A test body that runs past its limit fails the tests behind it at once** (`ViewHost.Turnstile`, the feedback
/// validator's read of 26 November 2026): such a body keeps the main loop, so the tests behind it could not run, and
/// each would wait for its suite's 10 minutes, one after the other in a serialized suite, while the Mac's test line
/// waits behind the run. These tests use a turnstile of their own, never the one of the view tests.
///
/// **A fault fails them, it never holds them**: a test that awaits a wait that nothing resumes does not end at its time
/// limit (26 November 2026: such a break held the Mac's test line for two hours). So each test awaits an `enter` only
/// once it has ended (`ended`, at most 1,000 reads 5 ms apart), and counts one that stands in the line, or that never
/// ends, as a fault.
@Suite(.timeLimit(.minutes(1))) struct TurnstileTests {
    /// Whether a test's `enter` has ended.
    private actor Ended {
        private(set) var value = false
        func set() { value = true }
    }

    /// A test's `enter`, whether it has ended, and whether it stood in the line (it waited for its turn) when it came.
    private struct Entry {
        let task: Task<Int, Error>
        let ended: Ended
        let waits: Bool
    }

    /// Whether `entry` has ended, read at most 1,000 times, 5 ms apart: a fault that keeps it waiting fails the test in
    /// about 5 s, and never holds it.
    private func ended(_ entry: Entry) async -> Bool {
        for _ in 0..<1_000 {
            if await entry.ended.value { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// Calls `enter` at `gate` and comes back once it has ended or stands in the line, whichever comes first, read at
    /// most 1,000 times, 5 ms apart (neither is a fault, and the test goes on as if it waited).
    private func enter(_ gate: ViewHost.Turnstile) async -> Entry {
        let before = await gate.waitingCount
        let ended = Ended()
        let task = Task<Int, Error> {
            do {
                let turn = try await gate.enter()
                await ended.set()
                return turn
            } catch {
                await ended.set()
                throw error
            }
        }
        for _ in 0..<1_000 {
            if await ended.value { return Entry(task: task, ended: ended, waits: false) }
            if await gate.waitingCount > before { return Entry(task: task, ended: ended, waits: true) }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("an enter neither ended nor joined the line")
        return Entry(task: task, ended: ended, waits: true)
    }

    /// Ends every turn that still stands, so that no task of a test is left in the line.
    private func release(_ gate: ViewHost.Turnstile) async {
        while await gate.waitingCount > 0 { await gate.leave() }
        await gate.leave()
    }

    @Test func theTestsBehindABodyPastItsLimitFailAtOnceUntilItEnds() async throws {
        let gate = ViewHost.Turnstile()
        let first = try await gate.enter()
        let behind = await enter(gate)
        #expect(behind.waits)
        await gate.overran(first, "the test's body did not end in 50 s")
        // the test that waited leaves the line with the body's words
        let left = await gate.waitingCount == 0
        #expect(left, "a test that waited behind the body still waits")
        if left {
            let out = await ended(behind)
            #expect(out, "a test that left the line never ended")
            if out { await #expect(throws: ViewHost.Missing.self) { try await behind.task.value } }
        }
        // a test that comes while the body runs past its limit fails at once, and never joins the line
        let late = await enter(gate)
        #expect(!late.waits, "a test that came while the body ran past its limit joined the line")
        if !late.waits { await #expect(throws: ViewHost.Missing.self) { try await late.task.value } }
        // the body ends: the next test has the next turn
        await gate.leave()
        let next = await enter(gate)
        #expect(!next.waits, "the turn after the body's end went to no test")
        if !next.waits { #expect(try await next.task.value == first + 1) }
        await release(gate)
    }

    @Test func aLateWordOfAnEndedTurnTouchesNoOtherTurn() async throws {
        let gate = ViewHost.Turnstile()
        let first = try await gate.enter()
        let second = await enter(gate)
        #expect(second.waits)
        await gate.leave()
        let handed = await ended(second)
        #expect(handed, "the turn after an ended body went to no test")
        guard handed else { return await release(gate) }
        let turn = try await second.task.value
        // the first body's timer spoke after its body had ended, and the turn had gone on
        await gate.overran(first, "the test's body did not end in 50 s")
        let third = await enter(gate)
        #expect(third.waits, "a late word of an ended turn failed a test that waited for the next turn")
        await gate.leave()
        if third.waits {
            let out = await ended(third)
            #expect(out, "the turn after the second body went to no test")
            if out { #expect(try await third.task.value == turn + 1) }
        }
        await release(gate)
    }
}
