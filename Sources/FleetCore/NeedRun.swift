import Foundation

/// **Run on the command of a hand step** (owner feature `need_run`, API 1.197; the owner, 16 November 2026, of a card
/// that told him to run one command on the Mac Studio: "would it be possible to have like a play button to run it? ...
/// like it happens with Claude Code? and then have like a hook?", then "Yes, as drawn" to its picture).
///
/// The manager names the one command of a hand step (`run_command`) and the Mac that it runs on (`run_on`). The card
/// shows Run on that command's code block. At his press this Mac runs it there, and its exit status and the end of its
/// output go to the hub as his answer (`PendingRequest.ran`), which the manager reads as data from that machine: the
/// hook. The rules here decide, as `DoorCall.checked` does for the door's card. The hub checks the same, and a command
/// that the hub takes and this Mac refuses is a card with no Run.
public enum NeedRun {
    public static let feature = "need_run"
    /// `run_on` of the owner's own Mac: the Mac where he presses Run.
    public static let ownMac = "mac"
    /// The most characters of a command (`hub.NEED_RUN_CHARS`): one line, which the card shows whole.
    public static let commandCharacters = 1000
    /// The most characters of the output that the answer carries (`hub.NEED_RUN_OUTPUT_CHARS`): its end, which says
    /// how the command ended. Characters as the hub counts them: Unicode scalars.
    public static let outputCharacters = 8000
    /// How the hub's answer of a press of Run begins (`hub.need_run_answer`): "Ran it on <where>".
    public static let answerPrefix = "Ran it on "
    /// The widest run of spaces in a command (`hub.NEED_RUN_GAP`): more can move a part of the command away from the part
    /// that he reads.
    public static let gapSpaces = 8

    /// **The command that Run runs for this item, or nil for an item that shows no Run**: an open item, whose task
    /// stands on the front of its card (`taskInFront`), that names a command and a place; the command passes
    /// `allowed`; and that task draws a code block whose text is that command exactly, by the parser that draws it
    /// (`MessageBlock`). So Run stands only on the block that shows what it runs.
    /// `running`: a run of it goes on, so its block keeps Stop also when the item closed meanwhile.
    public static func command(of need: OwnerNeed, running: Bool = false) -> String? {
        guard need.isOpen || running, need.taskInFront, let command = need.run_command, let place = need.run_on,
              !place.isEmpty, allowed(command),
              MessageBlock.parse(need.todo).contains(where: { $0.kind == .code && $0.text == command }) else { return nil }
        return command
    }

    /// **A command that this Mac runs at a press**: one line of printable ASCII, at most `commandCharacters`, with no
    /// space at either end, no run of more than `gapSpaces` spaces, not three backticks, and no `sudo`, which asks for a
    /// password that Run has no place for.
    /// Every other character can change what runs and not what he reads: one that draws nothing, one that draws as
    /// another letter, one that reorders the line, and a tab (`DoorCall.hidden`, which has the same rule).
    public static func allowed(_ command: String) -> Bool {
        guard !command.isEmpty, command.unicodeScalars.count <= commandCharacters,
              command.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }),
              command.first != " ", command.last != " ", !command.hasPrefix("```"),
              !command.contains(String(repeating: " ", count: gapSpaces + 1)) else { return false }
        return command.range(of: "(?<![A-Za-z0-9_-])sudo(?![A-Za-z0-9_-])", options: .regularExpression) == nil
    }

    /// Where Run runs an item's command.
    public enum Place: Equatable, Sendable {
        /// This Mac, in his own login shell.
        case thisMac
        /// A Mac of the fleet, over this Mac's SSH connection, with the SSH user and port that the team gives it.
        case machine(name: String, address: String, user: String, port: Int)
    }

    /// **Where this Mac runs an item's command, or nil where it cannot**: this Mac for `ownMac`; for a machine of the
    /// fleet, the reading of that machine that says macOS and has a valid SSH way (`MachineStatus.sshURL`: its address a
    /// number, its user a plain name, its port 1 to 65535). The card shows no Run where this is nil.
    public static func place(of need: OwnerNeed, machines: [MachineStatus]?) -> Place? {
        guard let on = need.run_on, !on.isEmpty else { return nil }
        if on == ownMac { return .thisMac }
        guard let reading = machines?.first(where: {
                  $0.machine == on && $0.sshURL != nil && ($0.os.name ?? "").hasPrefix("macOS") }),
              let ssh = reading.access?.ssh, let address = reading.address else { return nil }
        return .machine(name: on, address: address, user: ssh.user, port: ssh.port)
    }

    /// The words of the hub's answer of a press (`hub.need_run_answer`), which his answer on its way holds until the
    /// hub's copy comes: the place by its name, and the exit status when it is not 0.
    public static func answerWords(on place: String, status: Int) -> String {
        answerPrefix + (place == ownMac ? "the owner's Mac" : place) + (status == 0 ? "" : ", exit status \(status)")
    }

    /// What came of one run.
    public enum Outcome: Equatable, Sendable {
        /// The command ran there: its exit status (128 and the signal for one that a signal ended), and the end of its
        /// output, at most `outputCharacters`.
        case ran(status: Int, output: String)
        /// This Mac did not reach the shell there, so the command did not start: the last line that ssh or the shell
        /// wrote, for the line's hover.
        case notReached(String)
        /// He pressed Stop.
        case stopped
    }

    /// The end of an output, at most `outputCharacters` Unicode scalars, as the hub counts characters. **An output
    /// that is cut loses the part of a word at the cut**: a login holds no white space, and the hub masks a login only
    /// when it is whole, so the part of one after the cut would stay in the answer.
    public static func tail(_ output: String) -> String {
        let scalars = output.unicodeScalars
        guard scalars.count > outputCharacters else { return output }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: scalars.suffix(outputCharacters))
        if let space = kept.firstIndex(where: { $0.properties.isWhitespace }) {
            kept.removeSubrange(kept.startIndex...space)
        } else {
            kept.removeAll()
        }
        return String(kept)
    }

    /// **What the shell reads on its standard input**: a line that says it started, the command in a group whose own
    /// input is /dev/null and whose error output goes with its output, and a line that says that it ended, with its
    /// exit status. A command that reads its input reads nothing, and not the lines after it. **What the command writes
    /// before it ends, its error words too, comes on one channel, before the end line**: ssh carries error output on a
    /// channel of its own, and the end line came first on the run of 16 November 2026, so the answer lost gh's "not
    /// logged in to any hosts". What a process that the command leaves in the background writes later is not in the
    /// answer. The command never stands in an argument of a program, so no shell on this Mac or on the way reads it a
    /// second time.
    public static func script(_ command: String, marker: String) -> Data {
        Data("printf '%s\\n' '\(marker)'\n{ \(command)\n} < /dev/null 2>&1\nprintf '\\n%s %s\\n' '\(marker)-end' \"$?\"\n".utf8)
    }

    /// The output that came after the line that says the shell started, or nil when that line never came.
    public static func after(marker: String, in output: String) -> String? {
        guard let range = output.range(of: marker + "\n") else { return nil }
        return String(output[range.upperBound...])
    }

    /// **The command's output and exit status**, from what came after the start line: the end line says the status, and
    /// the output is what came before it. nil when no whole end line came: the command ended the shell itself (`exit`),
    /// or the connection went.
    public static func ending(marker: String, in after: String) -> (output: String, status: Int)? {
        guard let range = after.range(of: "\n" + marker + "-end ", options: .backwards) else { return nil }
        let rest = after[range.upperBound...]
        guard let newline = rest.firstIndex(of: "\n"), let status = Int(rest[..<newline]), (0...255).contains(status)
        else { return nil }
        return (String(after[..<range.lowerBound]), status)
    }
}

#if os(macOS)
/// **One run of an item's command**, which he can stop. It runs the login shell of the user there, with the command on
/// its standard input: his own on this Mac, or the one of the SSH user of a Mac of the fleet over `/usr/bin/ssh`, with
/// his own SSH settings and keys, as the Terminal button of that Mac's page does. Nothing waits for a time: the run
/// ends with the command's end line, when the shell ends, when ssh finds the connection gone (`ServerAliveCountMax`
/// answers that did not come), or at Stop.
///
/// **Known limits.** Stop on a Mac of the fleet ends ssh, and with it this Mac's wait, but no terminal stands between
/// ssh and the command there, so no hang-up signal reaches it: a command that writes nothing more runs on to its end
/// (one that writes gets SIGPIPE). Nothing is sent for a stopped run, and the card stays open. A terminal (`ssh -tt`)
/// would end it, and would also make the shell there interactive, with its prompts in the output. A connection that
/// goes after the command started gives ssh's own status, 255, with ssh's words in the output. The login shell is of
/// the family of sh (zsh, bash): the script's group and its end line are its syntax.
public final class NeedRunJob: @unchecked Sendable {
    public let command: String
    public let place: NeedRun.Place
    let shell: String
    let ssh: String
    private let lock = NSLock()
    private var child: Process?
    private var stopped = false
    /// The end line came: the command ended, and its result stands, also against a Stop after it.
    private var ended = false

    /// `shell` and `ssh`: the programs that a test puts in the place of his login shell and of ssh.
    public init(command: String, place: NeedRun.Place, shell: String? = nil, ssh: String = "/usr/bin/ssh") {
        self.command = command
        self.place = place
        self.shell = shell ?? NeedRunJob.loginShell()
        self.ssh = ssh
    }

    /// His login shell, as the user database names it, else zsh.
    public static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let name = entry.pointee.pw_shell {
            let shell = String(cString: name)
            if shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) { return shell }
        }
        return "/bin/zsh"
    }

    /// The program and its arguments. On a Mac of the fleet, ssh with no question to answer (`BatchMode`): a key that
    /// it does not hold, or a host key that it does not know, ends the run there as not reached. The login shell there
    /// sends its own error words, a profile's or a syntax error's, with its output, on ssh's one channel.
    func program() -> (executable: String, arguments: [String]) {
        switch place {
        case .thisMac:
            return (shell, ["-l"])
        case .machine(_, let address, let user, let port):
            return (ssh, ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=15",
                          "-o", "ServerAliveCountMax=4", "-p", String(port), "\(user)@\(address)",
                          "exec \"${SHELL:-/bin/sh}\" -l 2>&1"])
        }
    }

    public func run() async -> NeedRun.Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: self.blocking()) }
        }
    }

    /// **Stop**: the program ends, and on this Mac the command's own processes with it. A run whose command ended (its
    /// end line came, or its shell is gone) keeps its result: Stop has nothing left to end. Before the program started,
    /// the run does not start.
    public func stop() {
        lock.lock()
        let child = self.child
        if ended || (child != nil && child?.isRunning != true) {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        guard let child else { return }
        let pid = child.processIdentifier
        if case .thisMac = place { Self.terminateChildren(of: pid) }
        child.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if child.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// The end line came, on the reader's queue: the command ended. On a Mac of the fleet ssh waits on while a process
    /// that the command left in the background holds the session's output there, so this Mac ends ssh, as a closed
    /// Terminal window would. On this Mac the shell ends by itself.
    private func endLineCame() {
        lock.lock()
        ended = true
        let child = self.child
        lock.unlock()
        if case .machine = place, let child, child.isRunning { child.terminate() }
    }

    /// SIGTERM to each process whose parent is `pid`, by the kernel's own list.
    private static func terminateChildren(of pid: pid_t) {
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return }
        var children = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        for child in children.prefix(Int(max(found, 0))) where child > 0 { kill(child, SIGTERM) }
    }

    private func blocking() -> NeedRun.Outcome {
        let marker = "founderizer-run-" + UUID().uuidString.lowercased()
        let (executable, arguments) = program()
        // The output's pipe, made here so that its read end is read by events: the run ends with the command's end
        // line or with the shell, not when the pipe ends, because a process that the command leaves in the background
        // (`./server &`, `ssh -f`) keeps the pipe open for as long as it runs. Its read end goes to no child.
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { return .notReached(String(cString: strerror(errno))) }
        let readEnd = ends[0], writeEnd = ends[1]
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL) | O_NONBLOCK)
        let writer = FileHandle(fileDescriptor: writeEnd, closeOnDealloc: true)
        let child = Process(), input = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.standardOutput = writer
        child.standardError = writer
        child.standardInput = input
        // His own Mac: the home folder, as Terminal and an SSH login start there. The app's own folder is /.
        if case .thisMac = place { child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser }
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = "/usr/bin/false"      // nothing asks the owner for a password
        environment["DISPLAY"] = nil
        // his Homebrew programs, which a login shell finds by his own profile too
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        child.environment = environment
        lock.lock()
        if stopped {
            lock.unlock()
            close(readEnd)
            return .stopped
        }
        do { try child.run() } catch {
            lock.unlock()
            close(readEnd)
            return .notReached(error.localizedDescription)
        }
        self.child = child
        lock.unlock()
        try? writer.close()         // the shell has its own copy of this end; with this one open the pipe never ends
        // A program that ends before it has read all of its input closes the pipe: the write then fails with EPIPE,
        // which `try?` takes, and raises no SIGPIPE (LocalShell).
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let reader = OutputReader(fd: readEnd, marker: Data((marker + "\n").utf8),
                                  end: Data(("\n" + marker + "-end ").utf8)) { [weak self] in self?.endLineCame() }
        reader.start()
        try? input.fileHandleForWriting.write(contentsOf: NeedRun.script(command, marker: marker))
        try? input.fileHandleForWriting.close()
        child.waitUntilExit()
        let (before, after) = reader.finish()
        lock.lock()
        let wasStopped = stopped
        self.child = nil
        lock.unlock()
        // Stop came before any end line (stop() marks a run stopped only then): the run is stopped, also when the
        // shell, woken by the end of its command, printed the end line on its way out, with the status of the kill.
        if wasStopped { return .stopped }
        let afterText = after.map { String(decoding: $0, as: UTF8.self) }
        if let afterText, let end = NeedRun.ending(marker: marker, in: afterText) {
            return .ran(status: end.status, output: NeedRun.tail(end.output))
        }
        let status = child.terminationReason == .uncaughtSignal ? 128 + Int(child.terminationStatus)
            : Int(child.terminationStatus)
        guard let afterText else {
            let said = String(decoding: before, as: UTF8.self)
                .split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return .notReached(said)
        }
        return .ran(status: min(max(status, 0), 255), output: NeedRun.tail(afterText))
    }

    /// **The output of one run, read as it comes**, on a queue of its own, one read for each event, so that no writer
    /// holds the queue: what came before the start line (a profile's words, or ssh's own error), at most 64 KB, and what
    /// came after it, at most its last 256 KB, of which the answer keeps the end. It says once when the end line has
    /// come. `finish()` reads what the shell wrote before it ended and takes that; what a process that the command left
    /// in the background writes later is read and dropped, until it closes the pipe.
    private final class OutputReader: @unchecked Sendable {
        private let fd: Int32
        private let marker: Data
        private let end: Data
        private let endLineCame: () -> Void
        private let queue = DispatchQueue(label: "founderizer.need-run.output")
        private var source: DispatchSourceRead?
        private var before = Data()
        private var after: Data?
        private var taken = false
        private var ended = false
        private var endSaid = false

        init(fd: Int32, marker: Data, end: Data, endLineCame: @escaping () -> Void) {
            self.fd = fd
            self.marker = marker
            self.end = end
            self.endLineCame = endLineCame
        }

        /// The reader keeps itself until the pipe ends: a process that the command left in the background writes on
        /// into a pipe that is still read, as into a terminal that is still open, and gets no SIGPIPE from this Mac.
        /// The cancel of the source at the end lets its handlers go, and the reader with them.
        func start() {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let fd = self.fd
            source.setEventHandler { [self] in
                _ = readOnce()
                if ended { self.source?.cancel() }
            }
            source.setCancelHandler { close(fd) }
            self.source = source
            source.resume()
        }

        /// What the shell wrote before it ended: the part before the start line, and the part after it, or nil when
        /// that line never came. Called once, after the shell ended: it reads what the pipe holds, at most 1 MB, until
        /// the end line, and no more.
        func finish() -> (before: Data, after: Data?) {
            queue.sync {
                var read = 0
                while !ended, !endSaid, read < 1_048_576 {
                    let count = readOnce()
                    if count <= 0 { break }
                    read += count
                }
                taken = true
                if ended { source?.cancel() }
                return (before, after)
            }
        }

        /// On the queue: one read of the pipe. The bytes read, 0 at its end, -1 when it holds nothing now.
        @discardableResult private func readOnce() -> Int {
            guard !ended else { return 0 }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    if !taken { append(Data(buffer[0..<count])) }
                    return count
                }
                if count == 0 { ended = true; return 0 }
                if errno != EINTR { return -1 }     // nothing more now (EAGAIN), or the pipe failed
            }
        }

        private func append(_ piece: Data) {
            if var kept = after {
                kept.append(piece)
                if kept.count > 262_144 { kept = Data(kept.suffix(262_144)) }
                after = kept
                sayEnd(newBytes: piece.count)
                return
            }
            before.append(piece)
            if let range = before.range(of: marker) {
                after = Data(before[range.upperBound...])
                before = Data(before[..<range.lowerBound])
                sayEnd(newBytes: after?.count ?? 0)
            } else if before.count > 65_536 + marker.count {
                before = Data(before.suffix(65_536 + marker.count))     // the marker can still come whole
            }
        }

        /// Says once that the whole end line came, by the bytes that came last and the line before them.
        private func sayEnd(newBytes: Int) {
            guard !endSaid, let after else { return }
            let from = after.index(after.endIndex, offsetBy: -min(after.count, newBytes + end.count + 8))
            guard let range = after.range(of: end, options: .backwards, in: from..<after.endIndex),
                  after[range.upperBound...].contains(UInt8(ascii: "\n")) else { return }
            endSaid = true
            endLineCame()
        }
    }
}
#endif
