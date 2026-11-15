#if os(macOS)
import Foundation

/// **The sign-in of the provider's program, as the guide needs it** (spec section 3.2, lane S). The sign-in is the
/// program's own: the app reads no token and keeps none. It asks the program two things: whether it is signed in, and
/// with a plan or with a key. The program's answer also holds the account's address, which is not read here.
public enum GuideSignIn {
    public struct Status: Equatable, Sendable {
        public let signedIn: Bool
        /// With a plan or with a key, and the plan's name. nil when not signed in.
        public let account: GuideAccount?
        public init(signedIn: Bool, account: GuideAccount?) { self.signedIn = signedIn; self.account = account }
    }

    /// `claude auth status --json`: it prints `loggedIn`, `authMethod` and `subscriptionType`, and no token. It makes
    /// no call of a model.
    public static let statusArguments = ["auth", "status", "--json"]
    /// `claude auth login`: the provider's own flow in the owner's browser. How it behaves when an app starts it with
    /// no terminal is not proved (the spec's section 8, step B), so nothing here runs it.
    public static let loginArguments = ["auth", "login"]

    /// **The program's answer as a status**, or nil when it is none. `authMethod` is `claude.ai` for a plan, and each
    /// other method counts as a key. Only these three values are read.
    public static func read(_ output: String) -> Status? {
        // The answer is one JSON object. A line of another kind before it (a notice of the program) is passed over.
        guard let from = output.firstIndex(of: "{"), let to = output.lastIndex(of: "}"), from < to,
              let object = (try? JSONSerialization.jsonObject(with: Data(output[from...to].utf8))) as? [String: Any],
              let signedIn = object["loggedIn"] as? Bool else { return nil }
        guard signedIn else { return Status(signedIn: false, account: nil) }
        let plan = object["authMethod"] as? String == "claude.ai"
        return Status(signedIn: true,
                      account: GuideAccount(kind: plan ? .plan : .key,
                                            plan: plan ? GuideAccount.planName(object["subscriptionType"] as? String) : nil))
    }

    /// One command of the program to its end: its status and what it printed. The app's own, or a test's.
    public typealias Run = @Sendable (_ program: URL, _ arguments: [String], _ environment: [String: String]) async -> String?

    /// **Whether the program is signed in now**, or nil when it gave no answer. The program runs with the session's own
    /// small environment, so it reads the owner's sign-in and nothing of the app.
    public static func status(of program: URL, home: String = NSHomeDirectory(), user: String = NSUserName(),
                              run: Run = GuideSignIn.run) async -> Status? {
        await run(program, statusArguments, GuideCommand.environment(home: home, user: user)).flatMap(read)
    }

    /// The app's own run: the program's standard output, at most 64 KB of it, and nil when it could not start.
    public static let run: Run = { program, arguments, environment in
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(), output = Pipe()
                process.executableURL = program
                process.arguments = arguments
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { continuation.resume(returning: nil); return }
                // The answer is short and comes at once. A program that gives none in 30 seconds is stopped, and so
                // is one that prints more than an answer.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { if process.isRunning { process.terminate() } }
                var data = Data()
                while data.count < 65_536, let piece = try? output.fileHandleForReading.read(upToCount: 8192), !piece.isEmpty {
                    data.append(piece)
                }
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}
#endif
