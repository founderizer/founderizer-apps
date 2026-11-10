#if os(macOS)
import Foundation

/// One program on this Mac, its whole output and its status.
///
/// The install of a machine of a fleet runs `ssh` here, and the installer on an always-on Mac runs the join line
/// and `verify` there. Both need the same three things: the input written and closed before anything is read (which
/// is how a Tailscale key reaches a machine without ever standing in an argument), output that is bounded, and a
/// program that is stopped when it takes too long.
public enum LocalShell {
    public struct Answer: Sendable, Equatable {
        public let status: Int32
        public let output: String
        public var ok: Bool { status == 0 }
        /// The output as lines, with the empty ones left out.
        public var lines: [String] {
            output.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    public enum Failure: LocalizedError, Equatable, Sendable {
        case cannotStart(String)
        public var errorDescription: String? {
            switch self { case .cannotStart(let says): return says }
        }
    }

    public static func run(_ executable: String, _ arguments: [String], stdin: Data? = nil,
                           timeout: Double = 600) async throws -> Answer {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try blocking(executable, arguments, stdin: stdin, timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// One shell program, with the Homebrew folders in PATH: a Mac's own Python, git and tmux are there, and a
    /// non-interactive session does not have them otherwise.
    public static func sh(_ program: String, stdin: Data? = nil, timeout: Double = 600) async throws -> Answer {
        try await run("/bin/sh", ["-c", "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; export PATH; " + program],
                      stdin: stdin, timeout: timeout)
    }

    private static func blocking(_ executable: String, _ arguments: [String], stdin: Data?,
                                 timeout: Double) throws -> Answer {
        let child = Process(), output = Pipe(), input = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.standardOutput = output
        child.standardError = output
        child.standardInput = stdin == nil ? FileHandle.nullDevice : input
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = "/usr/bin/false"      // nothing asks the owner for a password, ever
        environment["DISPLAY"] = nil
        child.environment = environment
        do { try child.run() } catch {
            throw Failure.cannotStart("This Mac could not start \(executable): \(error.localizedDescription)")
        }
        if let stdin {
            // A program that ends before it has read all of its input closes the pipe: the write then fails with EPIPE,
            // which `try?` takes, and raises no SIGPIPE, which stopped the whole app (7 November 2026: a server went
            // down for its reboot while the door round gave it the door's bundle).
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? input.fileHandleForWriting.write(contentsOf: stdin)
            try? input.fileHandleForWriting.close()
        }
        let reader = output.fileHandleForReading
        let collected = Collected()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while let piece = try? reader.read(upToCount: 65_536), !piece.isEmpty { collected.append(piece) }
            done.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if child.isRunning {
            child.terminate()
            let hard = Date().addingTimeInterval(5)
            while child.isRunning && Date() < hard { Thread.sleep(forTimeInterval: 0.05) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        child.waitUntilExit()
        _ = done.wait(timeout: .now() + 5)
        return Answer(status: child.terminationStatus, output: collected.text)
    }

    /// The output of one program, read on a thread of its own and bounded, so a program that prints without end
    /// cannot fill this Mac's memory.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ piece: Data) {
            lock.lock(); defer { lock.unlock() }
            if data.count < 1_048_576 { data.append(piece) }
        }
        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
#endif
