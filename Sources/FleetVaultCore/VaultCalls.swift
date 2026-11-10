import Darwin
import Foundation

/// The requests of this vault (`request`, `cancel`): the child of each request that runs, the task attempts whose
/// requests are stopped, and the identity of each request that was started.
///
/// The journal is the vault's own protected record. A request is in it before its child gets anything to send, so a
/// vault that ends in the middle leaves the identity and the exact process of that request. The next vault process
/// ends that process, and it never starts the same identity again: after an end that is not known, the request can
/// have been sent. One lock makes the start of a request and a `cancel` of its task attempt one after the other.
///
/// A record loses its process only after a proof that the process is gone: the vault took the status of its own
/// child, or the system shows that the exact process of an earlier vault does not run. A time that ran out is no proof.
final class VaultCalls: @unchecked Sendable {
    /// One request in the journal. With `child`: its process is not proved gone. Without: the request was started.
    struct Record: Codable, Equatable, Sendable {
        struct Child: Codable, Equatable, Sendable {
            let pid: Int32
            /// The start time of the process (`VaultProcess.start`): the pid alone can name a later process.
            let start: Int
        }
        let request_id: String
        let agent: String
        let db: String
        let job: Int
        let task: String
        let attempt: Int
        var child: Child?
    }
    private struct Journal: Codable {
        var v = 1
        var calls: [Record]
    }

    /// A request whose child this vault process started.
    final class Running: @unchecked Sendable {
        let record: Record
        let scope: VaultCallScope
        let child: VaultCurl
        /// `canceled`: a `cancel` named this request. `ended`: the vault took the status of its child (`end`).
        fileprivate var canceled = false, ended = false
        fileprivate init(record: Record, scope: VaultCallScope, child: VaultCurl) {
            self.record = record; self.scope = scope; self.child = child
        }
    }

    /// `stopped`: a `cancel` named the task attempt. `repeated`: the journal has the identity. `unsaved`: the journal
    /// could not be read or written. In each of these the child gets nothing.
    enum Start { case started(Running), stopped, repeated, unsaved }

    /// The finished identities that stay in the journal, the stopped scopes that stay in memory, and the journal's size.
    static let kept = 256, stoppedKept = 1024, limit = 262_144

    /// The one lock. `end` signals it for a `cancel` that waits.
    private let state = NSCondition()
    private let store: any VaultJournalStore
    private let patience: TimeInterval
    private let look: @Sendable (pid_t) -> VaultProcess.State
    private var records: [Record]?
    private var running: [Running] = []
    private var stopped: [VaultCallScope] = []

    /// `patience`: the seconds that a `cancel` waits for the end of a child that it signalled, and that the first read
    /// of the journal waits for the end of what an earlier vault process left. `look` only for tests.
    init(store: any VaultJournalStore, patience: TimeInterval = 5,
         look: @escaping @Sendable (pid_t) -> VaultProcess.State = VaultProcess.state(of:)) {
        self.store = store; self.patience = patience; self.look = look
    }

    /// The journal. It is read one time. Each call ends what an earlier vault process left (`sweep`), and the first
    /// one also waits for the proof. Call with the lock.
    private func journal() throws -> [Record] {
        var wait = 0.0
        if records == nil {
            var read: [Record] = []
            if let data = try store.load(limit: Self.limit) {
                // A child of this vault has a pid above 1. A record with another pid is not this vault's, and a
                // signal to such a pid reaches many processes: that journal is not used.
                guard let journal = try? JSONDecoder().decode(Journal.self, from: data), journal.v == 1,
                      journal.calls.allSatisfy({ ($0.child?.pid ?? 2) > 1 }) else { throw VaultFailure.keychain }
                read = journal.calls
            }
            records = read
            wait = patience
        }
        let deadline = Date().addingTimeInterval(wait)
        var pause: UInt32 = 1_000
        while !sweep(), Date() < deadline { usleep(pause); pause = min(pause * 2, 100_000) }
        return records ?? []
    }

    private func save(_ records: [Record]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Journal(calls: records))
        guard data.count <= Self.limit else { throw VaultFailure.keychain }
        try store.save(data)
    }

    /// One look at each process that an earlier vault process left: a record with a process that this vault process
    /// did not start. A process that runs with the pid and the start time of its record gets the signal that ends
    /// it. The record loses the process only when the system shows that this exact process does not run. A process
    /// with the same pid and another start time is another process: it is not touched. True when no process of an
    /// earlier vault is left. Call with the lock.
    @discardableResult private func sweep() -> Bool {
        guard var all = records else { return false }
        var changed = false, clean = true
        for index in all.indices {
            guard let left = all[index].child, !running.contains(where: { $0.record.child == left }) else { continue }
            switch look(left.pid) {
            case .running(let start) where start == left.start:
                // `VaultCurl` starts each child as a process group that has the pid of the child.
                kill(-left.pid, SIGKILL); kill(left.pid, SIGKILL)
                clean = false
            case .unknown: clean = false
            case .running, .absent: all[index].child = nil; changed = true
            }
        }
        if changed { records = all; try? save(all) }
        return clean
    }

    /// At the start of the vault, and before a job uses up the hub's confirmation: reads the journal and ends what a
    /// vault process that ended left. False when the journal cannot be read.
    @discardableResult func recover() -> Bool { state.withLock { (try? journal()) != nil } }

    func isStopped(_ scope: VaultCallScope) -> Bool { state.withLock { stopped.contains(scope) } }

    /// Why a request gets no child, or nil. The identity comes first: a request that was started can have been sent,
    /// also in an attempt that is stopped now. Its answer must not be that nothing was sent. Call with the lock.
    private func refusal(of call: VaultCall, scope: VaultCallScope, in all: [Record]) -> Start? {
        if all.contains(where: { $0.request_id == call.requestID && $0.agent == scope.agent && $0.db == scope.db }) { return .repeated }
        return stopped.contains(scope) ? .stopped : nil
    }

    /// Before a job reads its login: what `begin` would refuse now, or nil. A request that was started, a stopped task
    /// attempt and a journal that cannot be read thus read no login.
    func refusal(of call: VaultCall, scope: VaultCallScope) -> Start? {
        state.withLock {
            guard let all = try? journal() else { return .unsaved }
            return refusal(of: call, scope: scope, in: all)
        }
    }

    /// Records a request and its child, which waits and has nothing to send. Only after this does the child get its
    /// request (`release`). A known identity and a stopped scope get no record.
    func begin(job: Int, call: VaultCall, scope: VaultCallScope, child: VaultCurl) -> Start {
        state.withLock {
            guard var all = try? journal() else { return .unsaved }
            if let refused = refusal(of: call, scope: scope, in: all) { return refused }
            let record = Record(request_id: call.requestID, agent: scope.agent, db: scope.db, job: job, task: scope.task, attempt: scope.attempt,
                                child: .init(pid: child.pid, start: child.start))
            // The oldest finished identities go; a record with a process always stays.
            let finished = all.indices.filter { all[$0].child == nil }
            let old = Set(finished.prefix(max(0, finished.count - Self.kept + 1)))
            all = all.indices.filter { !old.contains($0) }.map { all[$0] } + [record]
            guard (try? save(all)) != nil else { return .unsaved }
            records = all
            let entry = Running(record: record, scope: scope, child: child)
            running.append(entry)
            return .started(entry)
        }
    }

    /// The step before the child gets its request. False after a `cancel` of its scope: the child then gets nothing.
    func release(_ entry: Running) -> Bool { state.withLock { !entry.canceled && !entry.ended } }

    /// The end of a request: the record keeps the identity and loses the process. True when a `cancel` named this
    /// request. The vault has the status of the child after `run` or `abandon`; for a child that still runs, this
    /// ends it and takes the status first, so the record never loses a process that is not proved gone.
    @discardableResult func end(_ entry: Running) -> Bool {
        entry.child.abandon()
        return state.withLock {
            running.removeAll { $0 === entry }
            if !entry.ended, var all = records, let index = all.firstIndex(of: entry.record) {
                all[index].child = nil
                records = all
                try? save(all)
            }
            entry.ended = true
            state.broadcast()
            return entry.canceled
        }
    }

    /// The `cancel` of one scope. From now on no request of that scope starts, and each of its children that runs is
    /// ended. The count of those children, or nil when the vault cannot prove that every process of that task attempt
    /// is gone: the request path did not take the status of a child in time, a child of the attempt came with another
    /// key, a process that an earlier vault process left is not proved gone, or the journal cannot be read.
    func cancel(_ scope: VaultCallScope) -> Int? {
        state.lock(); defer { state.unlock() }
        // The newest scopes stay, and a scope that comes again is new.
        stopped.removeAll { $0 == scope }
        stopped.append(scope)
        if stopped.count > Self.stoppedKept { stopped.removeFirst() }
        guard (try? journal()) != nil else { return nil }
        let mine = running.filter { $0.scope == scope }
        for entry in mine { entry.canceled = true; entry.child.stop() }
        // The request path takes the status of each child and says so (`end`). The wait gives the lock to it.
        let deadline = Date().addingTimeInterval(patience)
        while mine.contains(where: { !$0.ended }), state.wait(until: deadline) {}
        // Every record of the attempt must be without a process now: those of this call, and all others.
        let left = (records ?? []).contains {
            $0.child != nil && $0.db == scope.db && $0.agent == scope.agent && $0.task == scope.task && $0.attempt == scope.attempt
        }
        return mine.allSatisfy(\.ended) && !left ? mine.count : nil
    }
}
