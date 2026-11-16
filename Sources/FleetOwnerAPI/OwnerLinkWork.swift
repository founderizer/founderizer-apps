import CryptoKit
import Foundation

/// **The table of work that outlives its call** (the secrets plan's step D, `agent-install-secrets-de-spec.md`,
/// section 2). A call of the link is one connection, and the listener cancels the call's task when the connection ends
/// (`ChannelListener`). That is right for a read. It is wrong for a tool whose work has more than one send
/// (`save_secret`: the entry in the hub's list, then the value in the vault): a caller that goes away in the middle
/// must not leave the first send done and the second one not made, and it must be able to ask later what came of it.
///
/// So the work is not the call's. The table starts it in a task of its own and keeps it (`begin`), and a call only
/// waits on it (`wait`): the end of a call ends its wait and never the work. A later call with the same `request_id`
/// joins the work, or reads its state (`state`).
///
/// **The table holds no value.** It keeps the id, the digest of the fields, the stage, the count of runs, the ended
/// answer and the tool's closure. What the closure holds (the tool's own box, with a value until the hub and the vault
/// have it) is the tool's to wipe, and it goes when the closure goes: the table drops the closure as soon as the work
/// can run no more.
///
/// **Each bound is a count.** No clock ends a work, judges one or drops one: `waitLimit` ends a wait and nothing else.
/// Nothing is kept on disk, so an app that quits has an empty table when it starts again.
@MainActor
public final class LinkWork {
    /// Where a work that runs is: at the first send (the hub's entry) or at the second (the vault's value).
    public enum Stage: String, Sendable { case registering, storing }

    /// **How a run ended.** `done`: the work is complete, with the tool's answer. `nothing`: nothing was saved, with
    /// the words that say why. `failed`: a send failed after something was saved, or may have been, with the words;
    /// `again` says whether the same call again makes the work go on with its remaining steps.
    ///
    /// **`nothing` is an answer of a first run only.** A work that ends with it leaves the table, and its caller
    /// reads that nothing was saved. After a run that failed with `again` true that can be false: the hub may hold
    /// the entry. So the table keeps a `nothing` of a later run as `failed` with the same words and `again` false,
    /// and the record stays.
    public enum Ended: Equatable, Sendable {
        case done(JSONValue)
        case nothing(String)
        case failed(String, again: Bool)
    }

    /// What the table says of one id: its work runs, at a stage, or it ended.
    public enum State: Equatable, Sendable {
        case running(Stage)
        case ended(Ended)
    }

    /// **What `begin` did, and what `check` says that it would do.** `started`: the id is not in the table, and its
    /// work runs now. `joined`: the table has the id with the same fields, so nothing new starts for the call's
    /// closure. `otherFields`: the table has the id with other fields. `busy`: another work runs now.
    public enum Begin: Equatable, Sendable { case started, joined, otherFields, busy }

    /// **A tool's work, as one run.** The run calls `stage` to tell the table where it is. `attempt` is the number of
    /// the run, from 1: a run with the number `triesMax` is the last one, so the tool ends it with its final words.
    /// The closure holds what a later run needs, and it never gets the cancel of a call.
    ///
    /// **A run must end.** The table uses no clock, so a run that never returns keeps the table busy, and its
    /// closure alive, until the app quits. Each send in a run thus carries its own bounded wait.
    ///
    /// **A run gives `nothing` only at attempt 1.** At a later attempt an earlier run may have saved something, so
    /// the table keeps such an answer as a failure for good (`Ended`).
    public typealias Run = @MainActor (_ stage: @MainActor (Stage) -> Void, _ attempt: Int) async -> Ended

    /// The bounds, each a count. `runningMax`: the works that run at one time. `keptMax`: the ended works that the
    /// table keeps. `callsMax`: the later calls of `begin` or `wait` after which an ended work leaves. `triesMax`:
    /// the runs of one work. `waitsMax`: the calls that wait at one time.
    ///
    /// **What `callsMax` is in a tool's calls.** One call of a tool that saves is a `begin` and a `wait`, so an
    /// ended work stays for about 8 repeats of its own call. In practice `keptMax` drops it first: four later saves
    /// that end.
    public static let runningMax = 1, keptMax = 4, callsMax = 16, triesMax = 3, waitsMax = 2

    /// The longest wait of one call. It ends no work and judges none, as the board's own (`SetupBoard.waitLimit`): it
    /// only stays under the 60 quiet reads after which the program stops (`ChannelClient.quietReads`).
    public static let waitLimit = Duration.seconds(40)

    /// One work of the table.
    @MainActor
    private final class Work {
        let id: String
        let digest: [UInt8]
        /// A new work is at its first send. A later run starts at the stage that the run before it reached, because
        /// that is where its remaining steps are.
        var stage = Stage.registering
        /// The runs so far, the one that runs now included.
        var tries = 0
        /// Nil while a run runs.
        var ended: Ended?
        /// The tool's closure, kept only while the work runs or can go on.
        var run: Run?
        /// The run that runs now. The table keeps it so that the work has an owner that is no call. No line of this
        /// file cancels it.
        var task: Task<Void, Never>?
        /// The calls of `begin` or `wait` since the work ended.
        var laterCalls = 0

        init(id: String, digest: [UInt8], run: @escaping Run) {
            self.id = id
            self.digest = digest
            self.run = run
        }

        var state: State { ended.map(State.ended) ?? .running(stage) }

        /// Whether the work failed and the same call again makes it run again.
        var goesOn: Bool {
            if case .failed(_, again: true)? = ended { return run != nil }
            return false
        }
    }

    let waitMax: Duration
    /// The works that run, and the ended ones in the order of their ends: an end moves its work to the back.
    private var works: [Work] = []
    private var waits: [UUID: (work: Work, resume: CheckedContinuation<State, Never>, clock: Task<Void, Never>)] = [:]

    /// A test gives a short `waitMax`.
    public init(waitMax: Duration = LinkWork.waitLimit) {
        self.waitMax = waitMax
    }

    // ------------------------------------------------------------ the key and the digest

    /// **The one form of a `request_id`**: a UUID in lower case, `^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$`, and
    /// not one byte more (no line end after it). The caller gives the id, or the program makes it before it reads a
    /// source. The app never makes it: an id made in the app is lost with a lost answer, and then nobody can ask about
    /// the work. Not on the main actor, because the program holds an id to this form too.
    public nonisolated static func isID(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 36 else { return false }
        for (place, byte) in bytes.enumerated() {
            switch place {
            case 8, 13, 18, 23:
                guard byte == UInt8(ascii: "-") else { return false }
            default:
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                        || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte) else { return false }
            }
        }
        return true
    }

    /// **What tells the caller's repeat from another save under the same id**: SHA-256 of the tool's name, a line end
    /// and the fields without `request_id`, written with sorted keys (`JSONValue.dumps`). It is never of the value,
    /// and never of whether a value part came: a compare of values would tell a caller whether two files hold the
    /// same secret. So this function takes no value.
    public nonisolated static func digest(tool: String, fields: [String: JSONValue]) -> [UInt8] {
        var rest = fields
        rest["request_id"] = nil
        return Array(SHA256.hash(data: Data((tool + "\n" + JSONValue.object(rest).dumps()).utf8)))
    }

    // ------------------------------------------------------------ the calls

    /// A read of the state: it changes nothing, and it is not one of the calls that `callsMax` counts. Nil for an id
    /// that the table does not have: nothing was saved under it, it ended long ago, or the app started again since.
    /// A tool's read of a state (a call with only the id) uses this and not `wait`, because a `wait` is a counted
    /// call.
    public func state(of id: String) -> State? {
        works.first { $0.id == id }?.state
    }

    /// **What `begin` would answer now** for this id and digest, with `started` for "its work would start". It
    /// changes nothing, starts nothing and leaves no record, and it is not one of the calls that `callsMax` counts,
    /// as `state(of:)`. A tool asks it before it reads the value and the clipboard, where macOS can ask the owner:
    /// `state(of:)` compares no digest and does not say `busy`.
    ///
    /// It is no promise. The tool has an `await` or more between `check` and `begin`, another call can come in
    /// them, and `begin` is the decision: after a `check` that said `started`, `begin` can still answer `busy`.
    public func check(id: String, digest: [UInt8]) -> Begin {
        decide(works.first { $0.id == id }, digest)
    }

    /// **A call that brings the fields of a save.** The table has no check of the id's form: the tool holds the id to
    /// `isID` before it comes here.
    /// - An id that the table does not have is a first call. Its work starts with `run`, in a task of the table's
    ///   own: `started`. While another work runs it does not start: `busy`.
    /// - An id that the table has, with another digest: `otherFields`, and nothing changes.
    /// - An id that the table has, with the same digest, is the caller's repeat after a lost answer: `joined`. The
    ///   table keeps the closure of the first call, and the `run` of this call is dropped without a run, so a value
    ///   that came again is never used. A joined work that failed and can go on runs again, with the closure of the
    ///   first call. While another work runs it cannot: `busy`, and the work stays as it is for a later call.
    ///
    /// **This is the decision, whatever a `check` said before it**: the table can have changed in the awaits between
    /// the two, so each of the four answers can come here.
    ///
    /// **No `await` between a `begin` and the `wait` or the `state(of:)` that follows it**, after `started` as after
    /// `joined`. A run that ends fast with `nothing` removes its record, and a `wait` after that answers nil. A
    /// `begin` itself never drops the work of its own id.
    ///
    /// **A tool's read of a state** (a call with only the id) does not come here and does not use `wait`: it uses
    /// `state(of:)`, because a `wait` is a counted call.
    public func begin(id: String, digest: [UInt8], run: @escaping Run) -> Begin {
        let own = works.first { $0.id == id }
        // The call gets its own answer first, and then it counts for the ended works. It never drops the work of its
        // own id: `joined` says that the table has that work, so the read that follows this call must find it.
        defer { counted(keeping: own) }
        let decision = decide(own, digest)
        switch decision {
        case .started:
            let work = Work(id: id, digest: digest, run: run)
            works.append(work)
            start(work, run)
        case .joined:
            if let own, own.goesOn, let kept = own.run { start(own, kept) }
        case .otherFields, .busy:
            break
        }
        return decision
    }

    /// **The one decision of `begin` and of `check`**, from the table as it is now. It changes nothing.
    private func decide(_ own: Work?, _ digest: [UInt8]) -> Begin {
        let free = works.filter { $0.ended == nil }.count < Self.runningMax
        guard let own else { return free ? .started : .busy }
        guard own.digest == digest else { return .otherFields }
        // A failed work that can go on needs the one place of a work that runs.
        if own.goesOn, !free { return .busy }
        return .joined
    }

    /// **Waits on a work**, and gives the state at the wait's end: the work's end, `waitMax`, or the call's cancel
    /// (its connection ended). The limit and the cancel end this wait only: the work runs on, and the answer is
    /// `running` with its stage. Answered at once, with the state as it is: an id that the table does not have (nil),
    /// a work that ended already, a call that is cancelled already, and one more call than `waitsMax`, so that
    /// waiting calls never take all the link's places from another caller. Each `wait` is a counted call, also one
    /// that is answered at once.
    public func wait(_ id: String) async -> State? {
        let work = works.first { $0.id == id }
        let now = work?.state
        // After the read: the sixteenth later call of an ended work still gets its answer.
        counted()
        guard let work, work.ended == nil, waits.count < Self.waitsMax, !Task.isCancelled else { return now }
        let key = UUID()
        let limit = waitMax
        let state: State = await withTaskCancellationHandler {
            await withCheckedContinuation { resume in
                let clock = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: limit)
                    self?.endWait(key)
                }
                waits[key] = (work, resume, clock)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.endWait(key) }
        }
        return state
    }

    /// The calls that wait now: for a test.
    var waiting: Int { waits.count }

    // ------------------------------------------------------------ a run and its end

    /// **One run of a work, in a task that is no child of the call**: such a task does not take the cancel of the
    /// call's task, so the call's end cannot stop the work between two sends. The task holds the table until the run
    /// ends, because the end must find its record.
    private func start(_ work: Work, _ run: @escaping Run) {
        work.tries += 1
        work.ended = nil
        work.laterCalls = 0
        let attempt = work.tries
        work.task = Task { @MainActor in
            let answer = await run({ work.stage = $0 }, attempt)
            self.end(work, with: answer)
        }
    }

    /// The end of a run: the record, the closure, the bound of the kept works, and then every call that waits.
    private func end(_ work: Work, with answer: Ended) {
        var answer = answer
        // **A work runs at most `triesMax` times.** The bound is the table's, so its state says so whatever the last
        // run said: a caller that reads `again` true calls again, and that call would start nothing.
        if case .failed(let words, again: true) = answer, work.tries >= Self.triesMax {
            answer = .failed(words, again: false)
        }
        // **`nothing` is true of a first run only.** A later run comes after a run that failed with `again` true, and
        // the hub may hold the entry of that one. If the work left the table now, its caller would read that nothing
        // was saved, and the same call again would be a new save. So it is a failure for good: the record stays, and
        // the closure goes below.
        if case .nothing(let words) = answer, work.tries > 1 {
            answer = .failed(words, again: false)
        }
        work.task = nil
        work.ended = answer
        work.laterCalls = 0
        works.removeAll { $0 === work }
        switch answer {
        case .nothing:
            // Nothing was saved, so there is nothing to ask about later. The work leaves the table at once, and the
            // same call again is a new save and no join.
            work.run = nil
        case .failed(_, again: true):
            // The closure stays: it holds what the remaining steps need.
            keep(work)
        case .done, .failed:
            // The work can run no more, so the closure goes now, and with it what the tool's box still holds.
            work.run = nil
            keep(work)
        }
        for (key, wait) in waits where wait.work === work {
            waits[key] = nil
            wait.clock.cancel()
            wait.resume.resume(returning: .ended(answer))
        }
    }

    /// An ended work goes to the back, and one more than `keptMax` drops the oldest: its record, and with it a
    /// closure that it still held.
    private func keep(_ work: Work) {
        works.append(work)
        if works.filter({ $0.ended != nil }).count > Self.keptMax,
           let oldest = works.firstIndex(where: { $0.ended != nil }) {
            works.remove(at: oldest)
        }
    }

    /// **One call of `begin` or `wait` was answered.** Each ended work has one more later call, and a work with
    /// `callsMax` of them leaves: its answer was there to be asked for that many times. A count and no clock, so a
    /// quiet link drops nothing. `own` is the work that a `begin` found under its id: that call counts for it and
    /// does not drop it, so it leaves at the first later call that is not a `begin` of its own id.
    private func counted(keeping own: Work? = nil) {
        for work in works where work.ended != nil { work.laterCalls += 1 }
        works.removeAll { $0.ended != nil && $0.laterCalls >= Self.callsMax && $0 !== own }
    }

    /// Ends one wait at its limit or at its call's cancel. A wait that is still here has a work that runs, because a
    /// work's end takes all its waits away first: so no wait is answered twice, and the answer is `running`.
    private func endWait(_ key: UUID) {
        guard let wait = waits.removeValue(forKey: key) else { return }
        wait.clock.cancel()
        wait.resume.resume(returning: .running(wait.work.stage))
    }
}
