import Darwin
import Foundation
import FleetCore
import FleetSetupIPC
import Security

final class SetupService: NSObject, FleetSetupServiceProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "fleet.setup.executor")
    private var process: pid_t = 0
    private var input: FileHandle?
    private var secrets: FileHandle?
    private var events: [SetupEvent] = []
    private var timeline = SetupTimeline()
    private var failure = ""
    private var lineBuffer = Data()
    private var retainedBytes = 0
    private var running = false
    private let screenSharing = ScreenSharingTunnels()
    private let kit = Bundle.main.resourceURL!.appendingPathComponent("FleetKit")
    private var python: String? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    func availability(reply: @escaping (Bool, String) -> Void) {
        let available = python != nil && FileManager.default.fileExists(atPath: kit.appendingPathComponent("onboard.py").path)
        reply(available, available ? "" : "The setup executor is not included in this build.")
    }

    // XPC reply blocks can be called from the worker queue below.
    private struct VersionReply: @unchecked Sendable { let call: (Data) -> Void }

    /// Runs `onboard.py version` with fixed arguments and returns its checked JSON line, or empty data.
    func executorVersion(reply: @escaping (Data) -> Void) {
        let reply = VersionReply(call: reply), kit = kit
        guard let python, FileManager.default.fileExists(atPath: kit.appendingPathComponent("onboard.py").path) else {
            reply.call(Data()); return
        }
        DispatchQueue.global(qos: .utility).async {
            let child = Process(), output = Pipe()
            child.executableURL = URL(fileURLWithPath: python)
            child.arguments = ["-B", kit.appendingPathComponent("onboard.py").path, "version"]
            child.currentDirectoryURL = kit
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["HOME"] = NSHomeDirectory()
            child.environment = environment
            child.standardInput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            child.standardOutput = output
            do { try child.run() } catch { reply.call(Data()); return }
            func wait(_ seconds: Double) {
                let deadline = Date().addingTimeInterval(seconds)
                while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            }
            wait(10)
            if child.isRunning {
                // A version answer takes well under a second. Stop the executor and give no answer.
                child.terminate(); wait(2)
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                reply.call(Data()); return
            }
            let data = (try? output.fileHandleForReading.read(upToCount: 4097)) ?? nil
            guard child.terminationReason == .exit, child.terminationStatus == 0, let data, data.count <= 4096,
                  let line = data.split(separator: 10).first,
                  let version = try? JSONDecoder().decode(SetupExecutor.self, from: Data(line)),
                  let checked = try? JSONEncoder().encode(version) else { reply.call(Data()); return }
            reply.call(checked)
        }
    }

    func start(configuration: Data, reply: @escaping (Bool, String) -> Void) {
        queue.sync {
            guard !running, configuration.count < 16_384 else { reply(false, "A setup run is already open."); return }
            do {
                let config = try JSONDecoder().decode(ServerConfiguration.self, from: configuration)
                try config.validate()
                guard let python, FileManager.default.fileExists(atPath: kit.appendingPathComponent("onboard.py").path) else {
                    reply(false, "The setup executor is not included in this build."); return
                }
                if config.auth == "identity", let key = config.identityFile, !FileManager.default.isReadableFile(atPath: key) {
                    reply(false, "The selected SSH key is not readable."); return
                }
                events = []; timeline = SetupTimeline(); failure = ""; retainedBytes = 0; lineBuffer = Data()
                try launch(python: python, arguments: config.arguments)
                reply(true, "")
            } catch { reply(false, "Setup could not start. Check the server fields and local Python installation.") }
        }
    }

    func readEvents(after: Int, reply: @escaping (Data, Bool, String) -> Void) {
        queue.sync {
            let batch = events.filter { $0.seq > after }.prefix(100)
            reply((try? JSONEncoder().encode(Array(batch))) ?? Data("[]".utf8), running, failure)
        }
    }

    func answer(prompt: String, value: Data, secret: Data?, reply: @escaping (Bool) -> Void) {
        queue.sync {
            guard running, let pending = timeline.prompt, pending.id == prompt, value.count < 4096,
                  let answer = try? JSONSerialization.jsonObject(with: value, options: .fragmentsAllowed) else { reply(false); return }
            guard pending.accepts(answer, secret: secret) else { reply(false); return }
            do {
                if pending.kind == "secret", let secret { try secrets?.write(contentsOf: secret + Data([10])) }
                var line = try JSONSerialization.data(withJSONObject: ["prompt": prompt, "answer": answer])
                line.append(10)
                try input?.write(contentsOf: line)
                timeline.answered(prompt)
                reply(true)
            } catch { reply(false) }
        }
    }

    func cancel(reply: @escaping () -> Void) { queue.sync { stop() }; reply() }
    func openScreenSharing(configuration: Data, reply: @escaping (Int, String) -> Void) {
        screenSharing.open(configuration, reply: reply)
    }
    func closeScreenSharing(configuration: Data, reply: @escaping () -> Void) {
        screenSharing.close(configuration, reply: reply)
    }
    func disconnected() { screenSharing.closeAll(); queue.async { self.stop() } }
    /// SIGTERM to the executor's process group ends a normal executor at once. The SIGKILL after 5 seconds is only for
    /// a child that ignores SIGTERM itself.
    private func stop() {
        guard process > 0 else { return }
        let pid = process
        kill(-pid, SIGTERM)
        queue.asyncAfter(deadline: .now() + 5) {
            if self.process == pid { kill(-pid, SIGKILL) }
        }
    }

    private func launch(python: String, arguments: [String]) throws {
        // Move pipe descriptors above stdio/FD 3 before spawn actions; this avoids dup2 collisions.
        func channel() throws -> [Int32] {
            var raw: [Int32] = [0, 0]
            guard pipe(&raw) == 0 else { throw SetupError.invalidConfiguration }
            let descriptors = raw.map { fcntl($0, F_DUPFD_CLOEXEC, 10) }
            raw.forEach { close($0) }
            guard descriptors.allSatisfy({ $0 >= 10 }) else {
                descriptors.filter { $0 >= 0 }.forEach { close($0) }; throw SetupError.invalidConfiguration
            }
            return descriptors
        }
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }
        let stdin = try channel(); opened += stdin
        let stdout = try channel(); opened += stdout
        let secret = try channel(); opened += secret
        let null = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard null >= 0 else { throw SetupError.invalidConfiguration }
        opened.append(null)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, stdin[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdout[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO)
        posix_spawn_file_actions_adddup2(&actions, secret[0], 3)
        for fd in opened where fd > 3 { posix_spawn_file_actions_addclose(&actions, fd) }
        guard posix_spawn_file_actions_addchdir_np(&actions, kit.path) == 0 else { throw SetupError.invalidConfiguration }
        // A child keeps every signal that its parent ignores, and the XPC runtime ignores SIGTERM in this service. The
        // executor gets the default action for every signal and an empty mask, so that Stop's SIGTERM ends it at once.
        var defaults = sigset_t(), unblocked = sigset_t()
        sigfillset(&defaults); sigemptyset(&unblocked)
        guard posix_spawnattr_setsigdefault(&attributes, &defaults) == 0, posix_spawnattr_setsigmask(&attributes, &unblocked) == 0 else {
            throw SetupError.invalidConfiguration
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        let args = [python, "-B", "-u", kit.appendingPathComponent("onboard.py").path] + arguments
        var argv = args.map { strdup($0) } + [nil]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOME"] = NSHomeDirectory()
        var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, python, &actions, &attributes, &argv, &envp) == 0 else { throw SetupError.invalidConfiguration }
        input = FileHandle(fileDescriptor: stdin[1], closeOnDealloc: true)
        secrets = FileHandle(fileDescriptor: secret[1], closeOnDealloc: true)
        let output = FileHandle(fileDescriptor: stdout[0], closeOnDealloc: true)
        opened.removeAll { [stdin[1], secret[1], stdout[0]].contains($0) }
        process = pid; running = true
        let childPID = pid
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = output.availableData
                if data.isEmpty { break }
                self.queue.sync { self.consume(data) }
            }
            var status: Int32 = 0
            while waitpid(childPID, &status, 0) < 0 && errno == EINTR {}
            self.queue.sync {
                self.running = false; self.process = 0
                try? self.input?.close(); try? self.secrets?.close()
                self.input = nil; self.secrets = nil
                if self.timeline.result == nil && self.failure.isEmpty {
                    self.failure = "Setup ended before verification (status \(status >> 8), signal \(status & 127)). Resume to check the server before continuing."
                }
            }
        }
    }

    private func consume(_ data: Data) {
        guard failure.isEmpty else { return }
        lineBuffer.append(data)
        guard lineBuffer.count <= 1_048_576 else { failure = "Setup status exceeded its size limit."; stop(); return }
        while let end = lineBuffer.firstIndex(of: 10) {
            let line = Data(lineBuffer[..<end]); lineBuffer.removeSubrange(...end)
            if line.isEmpty { continue }
            do {
                let event = try JSONDecoder().decode(SetupEvent.self, from: line)
                try timeline.append(event)
                retainedBytes += line.count
                guard retainedBytes <= 4_194_304 else { throw SetupError.invalidEvent }
                events.append(event)
            } catch { failure = "Setup returned an invalid status. Resume to check the server."; stop(); return }
        }
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    let requirement: String
    init(requirement: String) { self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.setCodeSigningRequirement(requirement)
        let service = SetupService()
        connection.exportedInterface = NSXPCInterface(with: FleetSetupServiceProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { service.disconnected() }
        connection.interruptionHandler = { service.disconnected() }
        connection.resume()
        return true
    }
}

// Bind the service to this exact containing app's designated signing requirement.
let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
var appCode: SecStaticCode?
var requirement: SecRequirement?
var requirementText: CFString?
guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &appCode) == errSecSuccess,
      let appCode, SecCodeCopyDesignatedRequirement(appCode, [], &requirement) == errSecSuccess,
      let requirement, SecRequirementCopyString(requirement, [], &requirementText) == errSecSuccess,
      let requirementText else { NSLog("Founderizer setup could not read the containing app signature"); exit(1) }
signal(SIGPIPE, SIG_IGN)
let delegate = Listener(requirement: requirementText as String)
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
