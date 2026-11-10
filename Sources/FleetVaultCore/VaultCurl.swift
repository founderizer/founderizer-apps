import Darwin
import Foundation

/// When a process started. With its pid, that names one process and no later one that gets the same pid.
enum VaultProcess {
    /// What the system says about a pid. `unknown`: it gave no answer, and that proves nothing.
    enum State: Equatable, Sendable { case running(start: Int), absent, unknown }

    /// The system's table of processes answers for a process of every user. It also has a process that ended and
    /// whose parent has not taken its status yet (`SZOMB`): that one runs nothing, so it is `absent`.
    static func state(of pid: pid_t) -> State {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return .unknown }
        guard size > 0 else { return .absent }
        guard size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { return .unknown }
        guard info.kp_proc.p_stat != SZOMB else { return .absent }
        return .running(start: Int(info.kp_proc.p_starttime.tv_sec) * 1_000_000 + Int(info.kp_proc.p_starttime.tv_usec))
    }

    /// In microseconds, or nil when the system does not show a process that runs with that pid now.
    static func start(of pid: pid_t) -> Int? {
        if case .running(let start) = state(of: pid) { return start }
        return nil
    }
}

/// One request of the system curl (`request`). Its options, its address and the saved value come on a pipe after the
/// start (`run`), never as an argument or in the environment: until then the process waits and has nothing to send.
/// It is a process group of its own, so `stop` ends all of it. curl follows no redirect and tries one time only.
final class VaultCurl: @unchecked Sendable {
    static let program = "/usr/bin/curl"
    /// `-q` comes first: no file of the user changes what curl does.
    static let arguments = ["-q", "--config", "/dev/fd/3"]
    static let environment = ["PATH=/usr/bin:/bin", "LANG=en_US.UTF-8"]
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: program) }

    /// The vault's ends of the pipes: the config and the body go in, the answer and one note line come out.
    private typealias Pipes = (config: Int32, input: Int32, output: Int32, notes: Int32)

    let pid: pid_t
    let start: Int
    private let lock = NSLock()
    /// With the one caller that uses them (`run` or `abandon`), these are -1.
    private var pipes: Pipes
    /// The wait status of the child, after the vault took it. From then on the pid is not the child's.
    private var status: Int32?
    /// In place of a status that the system did not give. It is not the status of an exit.
    private static let lost: Int32 = -1

    private init(pid: pid_t, start: Int, pipes: Pipes) { self.pid = pid; self.start = start; self.pipes = pipes }
    deinit { abandon() }

    /// Starts curl. It then waits for its config: it has no address, no value and no option that sends.
    static func start(withBody: Bool) throws -> VaultCurl {
        guard isAvailable else { throw VaultFailure.dependency }
        var opened: [Int32] = [], kept: [Int32] = []
        defer { opened.filter { !kept.contains($0) }.forEach { close($0) } }
        /// The same file as `fd` on a descriptor of 10 or more, which closes at an exec. `fd` itself closes. The file
        /// actions below write the child's descriptors 0 to 3, so no descriptor that they read can be one of those:
        /// the system gives the lowest free number, and that can be 0 to 3 in the vault.
        func high(_ fd: Int32) -> Int32 {
            guard fd >= 0 else { return -1 }
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 10); close(fd)
            if copy >= 0 { opened.append(copy) }
            return copy
        }
        func pipePair() throws -> (read: Int32, write: Int32) {
            var raw: [Int32] = [-1, -1]
            guard pipe(&raw) == 0 else { throw VaultFailure.dependency }
            let pair = raw.map(high)
            guard pair.allSatisfy({ $0 >= 10 }) else { throw VaultFailure.dependency }
            return (pair[0], pair[1])
        }
        let gate = try pipePair(), answer = try pipePair(), note = try pipePair()
        let body = withBody ? try pipePair() : nil
        // A request without a body gets an empty standard input.
        let input = body?.read ?? high(open("/dev/null", O_RDONLY | O_CLOEXEC))
        guard input >= 10 else { throw VaultFailure.dependency }
        // A child that ended must give a write error, not a signal that ends the vault.
        for fd in [gate.write, body?.write ?? -1] where fd >= 0 {
            guard fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw VaultFailure.dependency }
        }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw VaultFailure.dependency }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw VaultFailure.dependency }
        defer { posix_spawnattr_destroy(&attributes) }
        // The default action for every signal and an empty mask, so that `stop` always ends the child.
        var defaults = sigset_t(), unblocked = sigset_t()
        sigfillset(&defaults); sigemptyset(&unblocked)
        // The child has these four descriptors and no other one of the vault (`POSIX_SPAWN_CLOEXEC_DEFAULT`).
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        guard posix_spawn_file_actions_adddup2(&actions, input, 0) == 0, posix_spawn_file_actions_adddup2(&actions, answer.write, 1) == 0,
              posix_spawn_file_actions_adddup2(&actions, note.write, 2) == 0, posix_spawn_file_actions_adddup2(&actions, gate.read, 3) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0, posix_spawnattr_setsigmask(&attributes, &unblocked) == 0,
              posix_spawnattr_setflags(&attributes, Int16(flags)) == 0, posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw VaultFailure.dependency
        }
        var argv = ([program] + arguments).map { strdup($0) } + [nil]
        var env = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, program, &actions, &attributes, &argv, &env) == 0 else { throw VaultFailure.dependency }
        // The journal names the child by its pid and its start time. Without them it gets no request.
        guard let start = VaultProcess.start(of: pid) else {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            throw VaultFailure.dependency
        }
        kept = [gate.write, answer.read, note.read] + (body.map { [$0.write] } ?? [])
        return VaultCurl(pid: pid, start: start, pipes: (gate.write, body?.write ?? -1, answer.read, note.read))
    }

    /// The pipes go to the one caller that uses and closes them. A later caller gets none.
    private func take() -> Pipes {
        lock.withLock {
            defer { pipes = (-1, -1, -1, -1) }
            return pipes
        }
    }

    private static func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 { if errno == EINTR { continue }; return false }
                offset += count
            }
            return true
        }
    }

    /// What one request gave: the wait status of the child, the first bytes of the answer (at most `keep`), the count
    /// of all bytes of the answer, and the child's note line.
    struct Result: Sendable {
        let status: Int32
        let kept: Data
        let total: Int
        let note: Data
        /// The exit status of a child that ended by itself, or nil for a child that a signal ended.
        var exit: Int32? { status & 0x7f == 0 ? (status >> 8) & 0xff : nil }
    }

    /// Sends one request and waits for its end. The caller is not in a Swift task thread: this takes as long as the
    /// transfer. `limit`: the seconds that curl itself gets; a child that does not keep them is ended a little later.
    /// Only the first call sends. After it, and after `abandon`, the child has ended and nothing is sent.
    func run(_ plan: VaultCall.Plan, keep: Int, limit: Int) -> Result {
        let pipes = take()
        let late = DispatchWorkItem { [weak self] in self?.stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(limit + 10), execute: late)
        defer { late.cancel() }
        Self.send(plan, config: pipes.config, input: pipes.input)
        let answer = Self.collect(output: pipes.output, notes: pipes.notes, keep: keep)
        for fd in [pipes.output, pipes.notes] where fd >= 0 { close(fd) }
        return Result(status: finish(), kept: answer.kept, total: answer.total, note: answer.note)
    }

    /// For a child that gets no request: its pipes close, it is ended, and the vault takes its status. It sent nothing.
    /// After `run` this does nothing.
    func abandon() {
        let pipes = take()
        for fd in [pipes.config, pipes.input, pipes.output, pipes.notes] where fd >= 0 { close(fd) }
        stop()
        _ = finish()
    }

    /// Gives the child its request (`VaultCall.Plan`): the body first and to its end, then the config. The line that
    /// permits a protocol is the last one that curl gets. After a write that fails, nothing more goes to the child:
    /// a body or a config that is cut short sends nothing.
    private static func send(_ plan: VaultCall.Plan, config: Int32, input: Int32) {
        // A plan with a body is only for a child that reads one.
        var complete = config >= 0 && (plan.lead == nil) == (plan.body == nil) && (plan.body == nil || input >= 0)
        if complete, let lead = plan.lead, let body = plan.body { complete = write(config, lead) && write(input, body) }
        if input >= 0 { close(input) }
        if complete { _ = write(config, plan.config) }
        if config >= 0 { close(config) }
    }

    /// Reads the answer and the child's note to their ends, both at the same time, so that the child never waits
    /// for the vault. It keeps at most the first `keep` bytes of the answer and counts the rest. The note line is
    /// the last one that the child writes: of a long note, the end stays.
    private static func collect(output: Int32, notes: Int32, keep: Int) -> (kept: Data, total: Int, note: Data) {
        var kept = Data(), total = 0, note = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var sources = [pollfd(fd: output, events: Int16(POLLIN), revents: 0), pollfd(fd: notes, events: Int16(POLLIN), revents: 0)]
        while sources.contains(where: { $0.fd >= 0 }) {
            guard poll(&sources, 2, -1) > 0 else { if errno == EINTR { continue }; break }
            for index in sources.indices where sources[index].revents != 0 {
                let count = read(sources[index].fd, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                // The end, or an error. `poll` passes over a descriptor that is negative.
                guard count > 0 else { sources[index].fd = -1; continue }
                if index == 0 {
                    total += count
                    kept.append(contentsOf: buffer[..<min(count, max(0, keep - kept.count))])
                } else {
                    note.append(contentsOf: buffer[..<count])
                    if note.count > 4096 { note = Data(note.suffix(4096)) }
                }
            }
        }
        return (kept, total, note)
    }

    /// Waits for the end of the child and takes its status, one time. Until this has taken it, the pid is the
    /// child's own, also when the child has ended: `stop` thus never signals another process. The vault has no other
    /// wait for this child, and it does not ignore `SIGCHLD`.
    private func finish() -> Int32 {
        if let taken = lock.withLock({ status }) { return taken }
        // Without the lock, so that `stop` can end the child. This wait leaves the status with the system.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
        return lock.withLock {
            if let status { return status }
            var taken: Int32 = 0, result: pid_t
            repeat { result = waitpid(pid, &taken, 0) } while result < 0 && errno == EINTR
            let known = result == pid ? taken : Self.lost
            status = known
            return known
        }
    }

    /// Ends the child and all of its process group at once. curl keeps no state that needs an orderly end.
    func stop() { lock.withLock { if status == nil { kill(-pid, SIGKILL) } } }
}
