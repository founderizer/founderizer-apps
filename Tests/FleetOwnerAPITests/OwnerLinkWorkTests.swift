import CryptoKit
import Foundation
import Testing
@testable import FleetOwnerAPI

/// **`LinkWork`, the table of work that outlives its call**: a work that the end of its call does not end, the join
/// of a caller's repeat, the refusals (`otherFields`, `busy`), the three endings, the bounds by counts, the wait and
/// its three ends, the digest and the form of an id. Each work is a stand-in closure (`Job`): no test sends anything,
/// and no test sleeps for a fixed time. A test waits for a wait or for a run with a bound of looks (`until`), and
/// only a wait's own limit, which the test sets, takes real time.
///
/// **The time limit** is for a table whose wait lost its clock: a test that waits to a wait's limit would then wait
/// for ever, and the limit makes it a failure of that test and not a test process that never ends.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct OwnerLinkWorkTests {
    /// A limit that no passing test reaches: a wait that the work's end or a cancel must end fails within it.
    static let far = Duration.seconds(10)
    /// A limit that a test waits to its end.
    static let near = Duration.milliseconds(50)

    /// A made-up id of the one form.
    nonisolated static func id(_ number: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", number)
    }

    /// The digest of a made-up save of one key name.
    nonisolated static func digest(_ env: String = "EXAMPLE_API_KEY") -> [UInt8] {
        LinkWork.digest(tool: "save_secret", fields: ["kind": .string("api_key"), "env": .string(env)])
    }

    /// The answer of a work that is done, as a tool could give it: made up.
    static let receipt = JSONValue.object(["reference": .string("bws://" + id(77)), "state": .string("done")])

    /// **A stand-in for a tool's work.** It counts its runs with the number that the table gave each one, sets a
    /// stage at each of its steps when the test names one, stops after each step until the test opens it (`holds`),
    /// and ends each run with the answer that the test set for it.
    @MainActor
    final class Job {
        /// The number that the table gave each run, in the order of the runs.
        private(set) var attempts: [Int] = []
        /// Whether each run's own task was cancelled at the run's end.
        private(set) var cancelled: [Bool] = []
        /// What each run ends with: the first run takes the first, and the last one serves each later run too.
        let endings: [LinkWork.Ended]
        /// The steps of one run: the stage that each one sets, or nil for a step that sets none.
        var steps: [LinkWork.Stage?] = [nil]
        var holds: Bool
        private var held: [CheckedContinuation<Void, Never>] = []

        init(_ endings: LinkWork.Ended..., holds: Bool = false) {
            self.endings = endings
            self.holds = holds
        }

        /// Whether a run stands at a step and waits for `open`.
        var isHeld: Bool { !held.isEmpty }

        /// Lets the run that stands at a step go on.
        func open() {
            let list = held
            held = []
            for one in list { one.resume() }
        }

        private func hold() async {
            await withCheckedContinuation { held.append($0) }
        }

        var run: LinkWork.Run {
            { stage, attempt in
                self.attempts.append(attempt)
                for step in self.steps {
                    if let step { stage(step) }
                    if self.holds { await self.hold() }
                }
                self.cancelled.append(Task.isCancelled)
                return self.endings[min(attempt, self.endings.count) - 1]
            }
        }
    }

    /// What a closure can hold, and a weak look at it: the look is nil when nothing holds the closure any more.
    final class Box: Sendable {}
    @MainActor
    final class Look { weak var box: Box? }

    /// Begins a work whose closure holds a box, and gives back only the weak look: after this function the closure
    /// is held by the table alone, or by nothing when the table did not take it.
    func boxed(_ table: LinkWork, _ id: String, digest: [UInt8] = OwnerLinkWorkTests.digest(),
               _ endings: LinkWork.Ended...) -> (began: LinkWork.Begin, look: Look) {
        let box = Box()
        let look = Look()
        look.box = box
        let began = table.begin(id: id, digest: digest) { _, attempt in
            withExtendedLifetime(box) {}
            return endings[min(attempt, endings.count) - 1]
        }
        return (began, look)
    }

    /// What a call got, for a test that must see whether the call was answered without a wait for its task.
    @MainActor
    final class Answer {
        var came = false
        var state: LinkWork.State?
    }

    /// Asks `check` and then `begin` with nothing between the two, and holds the two answers to each other.
    func begun(_ table: LinkWork, _ id: String, digest: [UInt8] = OwnerLinkWorkTests.digest(),
               _ job: Job) -> LinkWork.Begin {
        let would = table.check(id: id, digest: digest)
        let did = table.begin(id: id, digest: digest, run: job.run)
        #expect(would == did)
        return did
    }

    /// Yields until `done`, with a bound of looks and no sleep: a regression fails at the expectation that follows.
    func until(_ done: () -> Bool) async {
        for _ in 0..<10_000 where !done() { await Task.yield() }
    }

    /// Room for a task that must not exist: it would run in these looks, and the expectation that follows sees it.
    func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    /// The state of an id when its work runs no more, without a call of `wait`: so nobody waits on the work, and
    /// no call is counted.
    func end(of id: String, in table: LinkWork) async -> LinkWork.State? {
        await until {
            if case .running? = table.state(of: id) { return false }
            return true
        }
        return table.state(of: id)
    }

    // ------------------------------------------------------------ a work and its call

    /// **The call is one task that begins the work and waits on it, as a tool does.** The cancel of that task (its
    /// connection ended) ends the wait at once and leaves the work as it was: it runs to its end, its own task never
    /// saw a cancel, and a later call reads its answer.
    @Test func aWorkOutlivesTheCancelOfItsCall() async {
        let table = LinkWork(waitMax: Self.far)
        let job = Job(.done(Self.receipt), holds: true)
        let call = Task { () -> LinkWork.State? in
            #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: job.run) == .started)
            return await table.wait(Self.id(1))
        }
        await until { table.waiting == 1 && job.isHeld }
        #expect(table.waiting == 1 && job.isHeld)
        call.cancel()
        // The cancel ended the wait, and not the limit: the wait is gone within a bound of looks, far under `far`.
        await until { table.waiting == 0 }
        #expect(table.waiting == 0)
        #expect(await call.value == .running(.registering))
        #expect(table.state(of: Self.id(1)) == .running(.registering))
        // A call that was cancelled before its wait began waits for nothing, and ends nothing too.
        let late = Task { await table.wait(Self.id(1)) }
        late.cancel()
        #expect(await late.value == .running(.registering))
        #expect(table.waiting == 0 && job.isHeld)
        job.open()
        #expect(await end(of: Self.id(1), in: table) == .ended(.done(Self.receipt)))
        #expect(job.attempts == [1])
        #expect(job.cancelled == [false])
        #expect(await table.wait(Self.id(1)) == .ended(.done(Self.receipt)))
    }

    /// **The caller's repeat after a lost answer**: the same id with the same fields joins the work, while it runs
    /// and after its end. The closure that came with the repeat is never run, and the first one runs once. Two calls
    /// that wait on the one work get its one end.
    @Test func theSameIdAndFieldsJoinAndRunNothingTwice() async {
        let table = LinkWork(waitMax: Self.far)
        let job = Job(.done(Self.receipt), holds: true)
        let repeated = Job(.done(.string("the answer of a second save")))
        #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: job.run) == .started)
        await until { job.isHeld }
        #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: repeated.run) == .joined)
        #expect(table.state(of: Self.id(1)) == .running(.registering))
        let one = Task { await table.wait(Self.id(1)) }
        let two = Task { await table.wait(Self.id(1)) }
        await until { table.waiting == 2 }
        #expect(table.waiting == 2)
        job.open()
        #expect(await one.value == .ended(.done(Self.receipt)))
        #expect(await two.value == .ended(.done(Self.receipt)))
        #expect(table.waiting == 0)
        // The repeat after the end: the same answer, and still no second run.
        #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: repeated.run) == .joined)
        #expect(await table.wait(Self.id(1)) == .ended(.done(Self.receipt)))
        await settle()
        #expect(job.attempts == [1] && repeated.attempts.isEmpty)
    }

    /// **An id belongs to one save.** Other fields under it are refused while its work runs, after a failure that can
    /// go on (the work does not go on for them) and after its end, and they change nothing.
    @Test func otherFieldsUnderOneIdAreRefused() async {
        let table = LinkWork(waitMax: Self.far)
        let failed = LinkWork.Ended.failed("Whether the hub took the entry is not known.", again: true)
        let job = Job(failed, .done(Self.receipt), holds: true)
        let other = Job(.done(.string("the answer of another save")))
        let otherDigest = Self.digest("OTHER_API_KEY")
        #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: job.run) == .started)
        await until { job.isHeld }
        #expect(table.begin(id: Self.id(1), digest: otherDigest, run: other.run) == .otherFields)
        #expect(table.state(of: Self.id(1)) == .running(.registering))
        job.open()
        #expect(await end(of: Self.id(1), in: table) == .ended(failed))
        #expect(table.begin(id: Self.id(1), digest: otherDigest, run: other.run) == .otherFields)
        await settle()
        #expect(table.state(of: Self.id(1)) == .ended(failed))
        #expect(job.attempts == [1])
        // The same fields make it go on, to its end. Then other fields are refused as before.
        job.holds = false
        #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: other.run) == .joined)
        #expect(await end(of: Self.id(1), in: table) == .ended(.done(Self.receipt)))
        #expect(table.begin(id: Self.id(1), digest: otherDigest, run: other.run) == .otherFields)
        await settle()
        #expect(table.state(of: Self.id(1)) == .ended(.done(Self.receipt)))
        #expect(job.attempts == [1, 2] && other.attempts.isEmpty)
    }

    /// **One work runs at a time.** A first call during it is refused and leaves no record. A failed work that can
    /// go on does not go on during it and stays as it is. The repeat of the running work's own call still joins.
    /// After the end, each of the two starts.
    @Test func oneWorkRunsAtATime() async {
        let table = LinkWork(waitMax: Self.far)
        let failed = LinkWork.Ended.failed("The value is not in the vault yet.", again: true)
        let first = Job(failed)
        #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: first.run) == .started)
        #expect(await end(of: Self.id(1), in: table) == .ended(failed))
        let second = Job(.done(Self.receipt), holds: true)
        #expect(table.begin(id: Self.id(2), digest: Self.digest(), run: second.run) == .started)
        await until { second.isHeld }
        let third = Job(.done(.string("the third")))
        #expect(table.begin(id: Self.id(3), digest: Self.digest(), run: third.run) == .busy)
        #expect(table.state(of: Self.id(3)) == nil)
        #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: third.run) == .busy)
        #expect(table.begin(id: Self.id(2), digest: Self.digest(), run: third.run) == .joined)
        await settle()
        #expect(table.state(of: Self.id(1)) == .ended(failed))
        #expect(first.attempts == [1] && second.attempts == [1] && third.attempts.isEmpty)
        second.open()
        #expect(await end(of: Self.id(2), in: table) == .ended(.done(Self.receipt)))
        #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: third.run) == .joined)
        #expect(await end(of: Self.id(1), in: table) == .ended(failed))
        #expect(first.attempts == [1, 2])
        #expect(table.begin(id: Self.id(3), digest: Self.digest(), run: third.run) == .started)
        #expect(await end(of: Self.id(3), in: table) == .ended(.done(.string("the third"))))
        #expect(third.attempts == [1])
        #expect(LinkWork.runningMax == 1)
    }

    /// **Nothing was saved, so the table keeps nothing.** The call that waited gets the words. After that a read of
    /// the id finds no work, and the same id again is a new save with its first run, also with other fields. A work
    /// that ends so while nobody waits leaves in the same way.
    @Test func aWorkWithNothingSavedLeavesTheTable() async {
        let table = LinkWork(waitMax: Self.far)
        let nothing = LinkWork.Ended.nothing("The hub refused the new entry. Nothing was saved.")
        let job = Job(nothing, holds: true)
        #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: job.run) == .started)
        let call = Task { await table.wait(Self.id(1)) }
        await until { table.waiting == 1 && job.isHeld }
        #expect(table.waiting == 1)
        job.open()
        #expect(await call.value == .ended(nothing))
        #expect(table.waiting == 0)
        #expect(table.state(of: Self.id(1)) == nil)
        #expect(await table.wait(Self.id(1)) == nil)
        let again = Job(nothing)
        #expect(table.begin(id: Self.id(1), digest: Self.digest("OTHER_API_KEY"), run: again.run) == .started)
        #expect(await end(of: Self.id(1), in: table) == nil)
        #expect(job.attempts == [1] && again.attempts == [1])
    }

    /// **A work runs at most three times.** The stand-in says at each run that the work can go on, also at the
    /// third: the bound is the table's, and its state says after the third run that the work goes on no more. Each
    /// later run is the first call's closure with the next number, and never the closure of the call that joined. A
    /// work that ended for good at its first run, or that was done at its second, runs no more.
    @Test func aFailedWorkGoesOnAtMostThreeTimes() async {
        let table = LinkWork(waitMax: Self.far)
        let words = "The value is not in the vault yet."
        let job = Job(.failed(words, again: true))
        let later = Job(.done(.string("the answer of a later call")))
        #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: job.run) == .started)
        #expect(await end(of: Self.id(1), in: table) == .ended(.failed(words, again: true)))
        #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: later.run) == .joined)
        // The work runs again at once: a call that waits now waits on the second run.
        #expect(table.state(of: Self.id(1)) == .running(.registering))
        #expect(await end(of: Self.id(1), in: table) == .ended(.failed(words, again: true)))
        #expect(job.attempts == [1, 2])
        #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: later.run) == .joined)
        #expect(await end(of: Self.id(1), in: table) == .ended(.failed(words, again: false)))
        #expect(job.attempts == [1, 2, 3])
        #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: later.run) == .joined)
        await settle()
        #expect(table.state(of: Self.id(1)) == .ended(.failed(words, again: false)))
        #expect(job.attempts == [1, 2, 3] && later.attempts.isEmpty)
        #expect(LinkWork.triesMax == 3)

        let fresh = LinkWork(waitMax: Self.far)
        let refused = Job(.failed("The vault refused the value.", again: false))
        #expect(fresh.begin(id: Self.id(2), digest: Self.digest(), run: refused.run) == .started)
        #expect(await end(of: Self.id(2), in: fresh) == .ended(.failed("The vault refused the value.", again: false)))
        #expect(fresh.begin(id: Self.id(2), digest: Self.digest(), run: refused.run) == .joined)
        let mended = Job(.failed(words, again: true), .done(Self.receipt))
        #expect(fresh.begin(id: Self.id(3), digest: Self.digest(), run: mended.run) == .started)
        #expect(await end(of: Self.id(3), in: fresh) == .ended(.failed(words, again: true)))
        #expect(fresh.begin(id: Self.id(3), digest: Self.digest(), run: mended.run) == .joined)
        #expect(await end(of: Self.id(3), in: fresh) == .ended(.done(Self.receipt)))
        #expect(fresh.begin(id: Self.id(3), digest: Self.digest(), run: mended.run) == .joined)
        await settle()
        #expect(refused.attempts == [1] && mended.attempts == [1, 2])
    }

    // ------------------------------------------------------------ the bounds

    /// **Each bound of the kept works is a count.**
    /// - Four ended works are kept, a failed one among them. A work with nothing saved takes no place. A fifth drops
    ///   the oldest, and only that one.
    /// - An ended work is there for 16 later calls of `begin` or `wait`: the sixteenth still gets its answer, and
    ///   then the work has left. A read of the state is no call.
    /// - When the sixteenth is the caller's repeat, `begin` says joined and leaves the work there for the read that
    ///   follows it. After that read the work has left.
    /// - No clock: three limits of a wait pass, and they end no work and drop none. Each of those waits counts as
    ///   the one call that it was, so the ended work leaves at its sixteenth call exactly.
    @Test func endedWorksLeaveByCountsNeverByAClock() async {
        let kept = LinkWork(waitMax: Self.far)
        let failed = LinkWork.Ended.failed("The value is not in the vault yet.", again: true)
        func ends(_ number: Int, _ answer: LinkWork.Ended) async {
            #expect(kept.begin(id: Self.id(number), digest: Self.digest(), run: Job(answer).run) == .started)
            let state = await end(of: Self.id(number), in: kept)
            if case .nothing = answer { #expect(state == nil) } else { #expect(state == .ended(answer)) }
        }
        await ends(1, .done(.int(1)))
        await ends(2, failed)
        await ends(3, .done(.int(3)))
        await ends(4, .done(.int(4)))
        await ends(6, .nothing("Nothing was saved."))
        for number in 1...4 { #expect(kept.state(of: Self.id(number)) != nil, "\(number)") }
        await ends(5, .done(.int(5)))
        #expect(kept.state(of: Self.id(1)) == nil)
        for number in 2...5 { #expect(kept.state(of: Self.id(number)) != nil, "\(number)") }
        #expect(kept.state(of: Self.id(2)) == .ended(failed))

        let counted = LinkWork(waitMax: Self.far)
        #expect(counted.begin(id: Self.id(1), digest: Self.digest(), run: Job(.done(Self.receipt)).run) == .started)
        #expect(await end(of: Self.id(1), in: counted) == .ended(.done(Self.receipt)))
        for _ in 0..<100 { #expect(counted.state(of: Self.id(1)) == .ended(.done(Self.receipt))) }
        for _ in 1..<LinkWork.callsMax { #expect(await counted.wait(Self.id(1)) == .ended(.done(Self.receipt))) }
        #expect(counted.state(of: Self.id(1)) == .ended(.done(Self.receipt)))
        #expect(await counted.wait(Self.id(1)) == .ended(.done(Self.receipt)))
        #expect(counted.state(of: Self.id(1)) == nil)
        #expect(await counted.wait(Self.id(1)) == nil)

        let repeated = LinkWork(waitMax: Self.far)
        #expect(repeated.begin(id: Self.id(1), digest: Self.digest(), run: Job(.done(Self.receipt)).run) == .started)
        #expect(await end(of: Self.id(1), in: repeated) == .ended(.done(Self.receipt)))
        for _ in 1..<LinkWork.callsMax { #expect(await repeated.wait(Self.id(9)) == nil) }
        #expect(repeated.begin(id: Self.id(1), digest: Self.digest(), run: Job(.done(.int(2))).run) == .joined)
        #expect(repeated.state(of: Self.id(1)) == .ended(.done(Self.receipt)))
        #expect(await repeated.wait(Self.id(1)) == .ended(.done(Self.receipt)))
        #expect(repeated.state(of: Self.id(1)) == nil)

        let quiet = LinkWork(waitMax: Self.near)
        #expect(quiet.begin(id: Self.id(1), digest: Self.digest(), run: Job(.done(Self.receipt)).run) == .started)
        #expect(await end(of: Self.id(1), in: quiet) == .ended(.done(Self.receipt)))
        let runs = Job(.done(.int(2)), holds: true)
        #expect(quiet.begin(id: Self.id(2), digest: Self.digest(), run: runs.run) == .started)          // call 1
        for _ in 0..<3 { #expect(await quiet.wait(Self.id(2)) == .running(.registering)) }              // calls 2 to 4
        #expect(quiet.state(of: Self.id(1)) == .ended(.done(Self.receipt)))
        #expect(quiet.state(of: Self.id(2)) == .running(.registering))
        for _ in 0..<11 {                                                                               // calls 5 to 15
            #expect(quiet.begin(id: Self.id(3), digest: Self.digest(), run: Job(.done(.int(3))).run) == .busy)
        }
        #expect(quiet.state(of: Self.id(1)) == .ended(.done(Self.receipt)))
        #expect(await quiet.wait(Self.id(9)) == nil)                                                    // call 16
        #expect(quiet.state(of: Self.id(1)) == nil)
        runs.open()
        #expect(await end(of: Self.id(2), in: quiet) == .ended(.done(.int(2))))
        #expect(runs.attempts == [1])
        #expect(LinkWork.keptMax == 4 && LinkWork.callsMax == 16)
    }

    /// **The limit ends a wait and nothing else.** The answer at the limit is the stage that the work is at; the
    /// work runs on to its next stage and to its end, in a task that was never cancelled. An id that the table does
    /// not have is answered at once.
    @Test func theWaitEndsAtItsLimitAndTheWorkGoesOn() async {
        let table = LinkWork(waitMax: Self.near)
        let job = Job(.done(Self.receipt), holds: true)
        job.steps = [.registering, .storing]
        #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: job.run) == .started)
        #expect(await table.wait(Self.id(1)) == .running(.registering))
        #expect(table.waiting == 0 && job.isHeld)
        job.open()
        await until { table.state(of: Self.id(1)) == .running(.storing) && job.isHeld }
        #expect(await table.wait(Self.id(1)) == .running(.storing))
        #expect(table.waiting == 0 && job.isHeld)
        job.open()
        #expect(await end(of: Self.id(1), in: table) == .ended(.done(Self.receipt)))
        #expect(job.attempts == [1] && job.cancelled == [false])
        #expect(await table.wait(Self.id(9)) == nil)
        #expect(LinkWork.waitLimit == .seconds(40))
    }

    /// **At most two calls wait.** One more is answered at once with the state as it is, and it takes no other
    /// call's place: its answer is there after a bound of looks, while the work still runs and long before a limit.
    /// The cancel of one waiting call ends that wait only and gives its place back: a new call takes the place and
    /// waits, and the two that wait get the work's end.
    @Test func oneMoreWaitThanTheBoundIsAnsweredAtOnce() async {
        let table = LinkWork(waitMax: Self.far)
        let job = Job(.done(Self.receipt), holds: true)
        #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: job.run) == .started)
        let one = Task { await table.wait(Self.id(1)) }
        let two = Task { await table.wait(Self.id(1)) }
        await until { table.waiting == LinkWork.waitsMax }
        #expect(table.waiting == LinkWork.waitsMax)
        // The third call is a task of its own, so that a wait in it shows: with no bound it would stand in the
        // table now, with no answer, until the limit.
        let third = Answer()
        let extra = Task {
            third.state = await table.wait(Self.id(1))
            third.came = true
        }
        await settle()
        #expect(third.came)
        #expect(third.state == .running(.registering))
        #expect(table.waiting == LinkWork.waitsMax && job.isHeld)
        await extra.value
        one.cancel()
        #expect(await one.value == .running(.registering))
        #expect(table.waiting == 1)
        let next = Task { await table.wait(Self.id(1)) }
        await until { table.waiting == LinkWork.waitsMax }
        #expect(table.waiting == LinkWork.waitsMax)
        job.open()
        #expect(await two.value == .ended(.done(Self.receipt)))
        #expect(await next.value == .ended(.done(Self.receipt)))
        #expect(table.waiting == 0)
        #expect(LinkWork.waitsMax == 2)
    }

    // ------------------------------------------------------------ a later run

    /// **A later run starts at the stage that the run before it reached**, because its remaining steps are there:
    /// run 1 reached `storing` and failed, and run 2, which sets no stage of its own here, is at `storing` while it
    /// runs. **A `wait` right after the `joined` that started the run again gets the second run's end**, and not the
    /// failure of the first.
    @Test func aLaterRunGoesOnFromItsStageAndItsCallGetsItsEnd() async {
        let table = LinkWork(waitMax: Self.far)
        let failed = LinkWork.Ended.failed("The value is not in the vault yet.", again: true)
        let job = Job(failed, .done(Self.receipt))
        job.steps = [.registering, .storing]
        #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: job.run) == .started)
        #expect(await end(of: Self.id(1), in: table) == .ended(failed))
        job.steps = [nil]
        job.holds = true
        let call = Task { () -> LinkWork.State? in
            let later = Job(.done(.string("the answer of a later call")))
            #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: later.run) == .joined)
            return await table.wait(Self.id(1))
        }
        await until { table.waiting == 1 && job.isHeld }
        #expect(table.waiting == 1 && job.isHeld)
        #expect(table.state(of: Self.id(1)) == .running(.storing))
        job.open()
        #expect(await call.value == .ended(.done(Self.receipt)))
        #expect(job.attempts == [1, 2])
    }

    /// **The count of later calls starts again at a later run and at its end.** Ten calls come after the first end,
    /// and ten more while the second run runs. After the second end the work is there for 16 later calls as a work
    /// that ended for the first time: with a count that went on, it would leave after six of them, or before.
    @Test func aLaterRunStartsTheCountOfLaterCallsAgain() async {
        let table = LinkWork(waitMax: Self.far)
        let failed = LinkWork.Ended.failed("The value is not in the vault yet.", again: true)
        let job = Job(failed)
        #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: job.run) == .started)
        #expect(await end(of: Self.id(1), in: table) == .ended(failed))
        for _ in 0..<10 { #expect(await table.wait(Self.id(9)) == nil) }
        job.holds = true
        #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: job.run) == .joined)
        await until { job.isHeld }
        for _ in 0..<10 { #expect(await table.wait(Self.id(9)) == nil) }
        #expect(table.state(of: Self.id(1)) == .running(.registering))
        job.open()
        #expect(await end(of: Self.id(1), in: table) == .ended(failed))
        for _ in 1..<LinkWork.callsMax { #expect(await table.wait(Self.id(9)) == nil) }
        #expect(table.state(of: Self.id(1)) == .ended(failed))
        #expect(await table.wait(Self.id(9)) == nil)
        #expect(table.state(of: Self.id(1)) == nil)
        #expect(job.attempts == [1, 2])
    }

    /// **`nothing` is an answer of a first run only.** Run 1 failed and can go on, so the hub may hold the entry.
    /// Run 2 says that nothing was saved: the table keeps that as a failure for good with the same words. The record
    /// stays, so a read does not say "no work" and the same call again is no new save, and the closure is dropped.
    @Test func nothingAtALaterRunIsAFailureForGood() async {
        let table = LinkWork(waitMax: Self.far)
        let failed = LinkWork.Ended.failed("Whether the hub took the entry is not known.", again: true)
        let words = "The hub refused the new entry. Nothing was saved."
        let (began, look) = boxed(table, Self.id(1), failed, .nothing(words))
        #expect(began == .started)
        #expect(await end(of: Self.id(1), in: table) == .ended(failed))
        #expect(look.box != nil)
        let later = Job(.done(.string("the answer of a later call")))
        #expect(table.begin(id: Self.id(1), digest: Self.digest(), run: later.run) == .joined)
        #expect(await end(of: Self.id(1), in: table) == .ended(.failed(words, again: false)))
        #expect(look.box == nil)
        // The same call again joins the record and starts nothing: no third run, and no new save under the id.
        #expect(begun(table, Self.id(1), later) == .joined)
        await settle()
        #expect(table.state(of: Self.id(1)) == .ended(.failed(words, again: false)))
        #expect(later.attempts.isEmpty)
    }

    // ------------------------------------------------------------ the check before a begin

    /// **`check` says what `begin` would answer now, and changes nothing.** Each of the four answers comes, and with
    /// nothing between the two, `begin` gives the same one (`begun`). A check starts no work, leaves no record, makes
    /// no failed work go on, and is no counted call: 300 checks after 15 later calls drop nothing, and the one
    /// counted call after them does.
    @Test func aCheckSaysWhatBeginWouldAndChangesNothing() async {
        let table = LinkWork(waitMax: Self.far)
        let failed = LinkWork.Ended.failed("The value is not in the vault yet.", again: true)
        let other = Self.digest("OTHER_API_KEY")
        let never = Job(.done(.string("the answer of a call that starts nothing")))
        // An empty table: the work would start, and the check started none.
        #expect(table.check(id: Self.id(1), digest: Self.digest()) == .started)
        #expect(table.state(of: Self.id(1)) == nil)
        let first = Job(failed)
        #expect(begun(table, Self.id(1), first) == .started)
        #expect(await end(of: Self.id(1), in: table) == .ended(failed))
        // A failed work that can go on: the same fields would join it, and the check does not make it go on.
        #expect(table.check(id: Self.id(1), digest: Self.digest()) == .joined)
        #expect(table.check(id: Self.id(1), digest: other) == .otherFields)
        await settle()
        #expect(table.state(of: Self.id(1)) == .ended(failed))
        #expect(first.attempts == [1])
        // While another work runs: a first call and the failed work are busy, and the running work's own call joins.
        let second = Job(.done(Self.receipt), holds: true)
        #expect(begun(table, Self.id(2), second) == .started)
        await until { second.isHeld }
        #expect(begun(table, Self.id(3), never) == .busy)
        #expect(table.state(of: Self.id(3)) == nil)
        #expect(begun(table, Self.id(1), never) == .busy)
        #expect(begun(table, Self.id(1), digest: other, never) == .otherFields)
        #expect(begun(table, Self.id(2), never) == .joined)
        #expect(begun(table, Self.id(2), digest: other, never) == .otherFields)
        second.open()
        #expect(await end(of: Self.id(2), in: table) == .ended(.done(Self.receipt)))
        // After the end: the work that is done is joined, and the failed one is joined and goes on.
        #expect(begun(table, Self.id(2), never) == .joined)
        #expect(begun(table, Self.id(1), never) == .joined)
        #expect(await end(of: Self.id(1), in: table) == .ended(failed))
        #expect(first.attempts == [1, 2] && second.attempts == [1] && never.attempts.isEmpty)

        let counted = LinkWork(waitMax: Self.far)
        #expect(counted.begin(id: Self.id(1), digest: Self.digest(), run: Job(.done(Self.receipt)).run) == .started)
        #expect(await end(of: Self.id(1), in: counted) == .ended(.done(Self.receipt)))
        for _ in 1..<LinkWork.callsMax { #expect(await counted.wait(Self.id(9)) == nil) }
        for _ in 0..<100 {
            #expect(counted.check(id: Self.id(1), digest: Self.digest()) == .joined)
            #expect(counted.check(id: Self.id(1), digest: other) == .otherFields)
            #expect(counted.check(id: Self.id(2), digest: Self.digest()) == .started)
        }
        #expect(counted.state(of: Self.id(1)) == .ended(.done(Self.receipt)))
        #expect(counted.state(of: Self.id(2)) == nil)
        #expect(await counted.wait(Self.id(9)) == nil)
        #expect(counted.state(of: Self.id(1)) == nil)
        #expect(counted.check(id: Self.id(1), digest: Self.digest()) == .started)
    }

    // ------------------------------------------------------------ the digest, the closure, the id

    /// **The digest is of the tool's name and the fields without `request_id`**, in one written form. A value is no
    /// input of it, so two saves of the same fields have one digest whatever their values are, and no answer can
    /// tell a caller whether two values are equal.
    @Test func theDigestIsOfTheFieldsAndNeverOfAValue() {
        // The tool's name and the fields are the only inputs: this line does not build with a value among them.
        let digest: (String, [String: JSONValue]) -> [UInt8] = LinkWork.digest(tool:fields:)
        let fields: [String: JSONValue] = ["kind": .string("api_key"), "env": .string("EXAMPLE_API_KEY"),
                                           "from": .string("file")]
        let written = "save_secret\n{\"env\": \"EXAMPLE_API_KEY\", \"from\": \"file\", \"kind\": \"api_key\"}"
        #expect(digest("save_secret", fields) == Array(SHA256.hash(data: Data(written.utf8))))
        #expect(digest("save_secret", fields).count == 32)
        // The id is no part of it: the caller's repeat has the same digest, and so has the same save under a new id.
        for id in [Self.id(1), Self.id(2)] {
            var named = fields
            named["request_id"] = .string(id)
            #expect(digest("save_secret", named) == digest("save_secret", fields))
        }
        // Another tool, another text of a field, one field more and one field less: each is another save.
        var changed = fields
        changed["env"] = .string("OTHER_API_KEY")
        var more = fields
        more["url"] = .string("https://api.example.com")
        var less = fields
        less["from"] = nil
        let others = [digest("save_bot_token", fields), digest("save_secret", changed), digest("save_secret", more),
                      digest("save_secret", less), digest("save_secret", [:])]
        #expect(Set(others + [digest("save_secret", fields)]).count == others.count + 1)
    }

    /// **The closure goes when the work can run no more**, and with it what the tool put in it: at done, at a
    /// failure for good, at nothing saved, at the third run, and when the record of a work that could go on leaves,
    /// by its 16 later calls or because four later works ended.
    /// While a failed work can go on, the closure stays. The closure of a call that the table did not start a work
    /// for (a join, other fields, a busy table) is never kept.
    @Test func theClosureIsDroppedWhenAWorkEndsForGood() async {
        let words = "The value is not in the vault yet."
        let failed = LinkWork.Ended.failed(words, again: true)
        for answer in [LinkWork.Ended.done(Self.receipt), .failed("The vault refused the value.", again: false),
                       .nothing("Nothing was saved.")] {
            let table = LinkWork(waitMax: Self.far)
            let (began, look) = boxed(table, Self.id(1), answer)
            #expect(began == .started)
            #expect(look.box != nil, "\(answer)")
            _ = await end(of: Self.id(1), in: table)
            #expect(look.box == nil, "\(answer)")
        }

        // A failed work that can go on keeps its closure, to the third run.
        let table = LinkWork(waitMax: Self.far)
        let (began, look) = boxed(table, Self.id(1), failed)
        #expect(began == .started)
        #expect(await end(of: Self.id(1), in: table) == .ended(failed))
        #expect(look.box != nil)
        let joined = boxed(table, Self.id(1), .done(Self.receipt))
        #expect(joined.began == .joined && joined.look.box == nil)
        #expect(await end(of: Self.id(1), in: table) == .ended(failed))
        #expect(look.box != nil)
        #expect(boxed(table, Self.id(1), failed).began == .joined)
        #expect(await end(of: Self.id(1), in: table) == .ended(.failed(words, again: false)))
        #expect(look.box == nil)

        // A closure that the table did not take: other fields, and a table that is busy.
        let other = boxed(table, Self.id(1), digest: Self.digest("OTHER_API_KEY"), .done(Self.receipt))
        #expect(other.began == .otherFields && other.look.box == nil)
        let job = Job(.done(Self.receipt), holds: true)
        #expect(table.begin(id: Self.id(2), digest: Self.digest(), run: job.run) == .started)
        await until { job.isHeld }
        let busy = boxed(table, Self.id(3), .done(Self.receipt))
        #expect(busy.began == .busy && busy.look.box == nil)
        job.open()
        #expect(await end(of: Self.id(2), in: table) == .ended(.done(Self.receipt)))

        // The record of a work that could go on leaves after its 16 later calls, and its closure with it.
        let counted = LinkWork(waitMax: Self.far)
        let left = boxed(counted, Self.id(1), failed)
        #expect(await end(of: Self.id(1), in: counted) == .ended(failed))
        for _ in 1..<LinkWork.callsMax { #expect(await counted.wait(Self.id(9)) == nil) }
        #expect(left.look.box != nil)
        #expect(await counted.wait(Self.id(9)) == nil)
        #expect(counted.state(of: Self.id(1)) == nil)
        #expect(left.look.box == nil)

        // The record of a work that could go on falls out when four later works have ended, and its closure with
        // it: three later works leave it there, and the fourth takes it away.
        let full = LinkWork(waitMax: Self.far)
        let oldest = boxed(full, Self.id(1), failed)
        #expect(await end(of: Self.id(1), in: full) == .ended(failed))
        for number in 2...(LinkWork.keptMax + 1) {
            #expect(full.state(of: Self.id(1)) == .ended(failed), "\(number)")
            #expect(oldest.look.box != nil, "\(number)")
            let later = Job(.done(Self.receipt))
            #expect(full.begin(id: Self.id(number), digest: Self.digest(), run: later.run) == .started)
            #expect(await end(of: Self.id(number), in: full) == .ended(.done(Self.receipt)))
        }
        #expect(full.state(of: Self.id(1)) == nil)
        #expect(oldest.look.box == nil)
    }

    /// The program's side is not on the main actor, and it holds an id to the same form.
    nonisolated static func formInTheProgram(_ text: String) -> Bool { LinkWork.isID(text) }

    /// **An id has one form**: a UUID in lower case with its four hyphens, 36 bytes and not one more. The check is
    /// held to the form as the spec writes it, as a pattern, for each example.
    @Test func anIdHasOneForm() throws {
        let example = "0b6f3c1e-58a2-4d7b-9e10-3c5a7f2d4e61"
        let right = [example, "00000000-0000-0000-0000-000000000000", "ffffffff-ffff-ffff-ffff-ffffffffffff",
                     UUID().uuidString.lowercased(), Self.id(1)]
        let wrong = [
            "", "0", example.uppercased(), "0B6f3c1e-58a2-4d7b-9e10-3c5a7f2d4e61",
            example.replacingOccurrences(of: "-", with: ""),                      // 32 digits and no hyphen
            String(example.dropLast()), example + "1", example + "\n", " " + example, example + " ",
            "{" + String(example.dropFirst().dropLast()) + "}",
            example.replacingOccurrences(of: "-", with: "_"),
            "0b6f3c1e5-8a2-4d7b-9e10-3c5a7f2d4e61",                               // a hyphen one place late
            "0b6f3c1e-58a2-4d7b-9e10-3c5a7f2d4e6g",                               // a letter after f
            "0b6f3c1e-58a2-4d7b-9e10-3c5a7f2d4e6\u{FF11}",                        // a digit of full width
            "\u{0660}b6f3c1e-58a2-4d7b-9e10-3c5a7f2d4e61",                        // an Arabic-Indic zero
            "0b6f3c1e-58a2-4d7b-9e10-3c5a7f2d4e6e\u{0301}",                       // a letter with a mark on it
            example + "\u{0}", "urn:uuid:" + example,
        ]
        let form = try Regex("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$")
        for text in right {
            #expect(LinkWork.isID(text), "\(text)")
            #expect(text.wholeMatch(of: form) != nil, "\(text)")
            #expect(Self.formInTheProgram(text), "\(text)")
        }
        for text in wrong {
            #expect(!LinkWork.isID(text), "\(text.debugDescription)")
            #expect(text.wholeMatch(of: form) == nil, "\(text.debugDescription)")
        }
    }
}
