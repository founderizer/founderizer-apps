import Darwin
import Foundation

/// Fixed, bundled programs only. Values travel in anonymous pipes, never argv, env or files.
final class VaultPrograms: @unchecked Sendable {
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func run(_ name: String, arguments: [String], input: Data = Data(), identity: Data? = nil) throws -> Data {
        guard ["age", "age-keygen"].contains(name) else { throw VaultFailure.dependency }
        let executable = directory.appendingPathComponent(name).path
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw VaultFailure.dependency }
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }
        func pipePair() throws -> [Int32] {
            var raw: [Int32] = [0, 0]
            guard pipe(&raw) == 0 else { throw VaultFailure.dependency }
            let pair = raw.map { fcntl($0, F_DUPFD_CLOEXEC, 10) }; raw.forEach { close($0) }
            guard pair.allSatisfy({ $0 >= 10 }) else {
                pair.filter { $0 >= 0 }.forEach { close($0) }; throw VaultFailure.dependency
            }
            opened += pair
            return pair
        }
        let stdin = try pipePair(), stdout = try pipePair(), key = try pipePair()
        let null = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard null >= 0 else { throw VaultFailure.dependency }; opened.append(null)
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, stdin[0], 0)
        posix_spawn_file_actions_adddup2(&actions, stdout[1], 1)
        posix_spawn_file_actions_adddup2(&actions, null, 2)
        if identity != nil { posix_spawn_file_actions_adddup2(&actions, key[0], 3) }
        for fd in opened where fd > 3 { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let environment: [String] = ["PATH=/usr/bin:/bin", "LANG=en_US.UTF-8"]
        var env = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable, &actions, &attributes, &argv, &env) == 0 else {
            throw VaultFailure.dependency
        }
        let child = Child(pid: pid)
        let timeout = DispatchWorkItem { child.stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        for fd in [stdin[0], stdout[1], key[0]] { close(fd); opened.removeAll { $0 == fd } }
        for (fd, data) in [(stdin[1], input), (key[1], identity ?? Data())] {
            opened.removeAll { $0 == fd }
            DispatchQueue.global().async {
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                try? handle.write(contentsOf: data); try? handle.close()
            }
        }
        let output = FileHandle(fileDescriptor: stdout[0], closeOnDealloc: false)
        var result = Data()
        while true {
            let part = output.availableData
            if part.isEmpty { break }
            result.append(part)
            if result.count > 1_048_576 { child.stop(); break }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        child.finished(); timeout.cancel()
        guard status == 0, result.count <= 1_048_576 else { throw VaultFailure.handover }
        return result
    }

    private final class Child: @unchecked Sendable {
        private let lock = NSLock()
        private let pid: pid_t
        private var running = true
        init(pid: pid_t) { self.pid = pid }
        func stop() { lock.withLock { if running { kill(-pid, SIGKILL) } } }
        func finished() { lock.withLock { running = false } }
    }
}

public final class VaultIdentity: @unchecked Sendable {
    private let keychain: VaultKeychain
    private let programs: VaultPrograms
    public init(keychain: VaultKeychain, programs: URL) {
        self.keychain = keychain; self.programs = VaultPrograms(directory: programs)
    }

    public func createIfMissing() throws {
        if try keychain.readIfPresent("age") != nil { return }
        let identity = try programs.run("age-keygen", arguments: [])
        _ = try Self.recipient(identity)
        try keychain.create(identity, item: "age")       // a new key never takes the place of one (package 7)
    }

    public func recipient() throws -> String { try Self.recipient(keychain.read("age")) }

    public func importIdentity(_ data: Data) throws {
        guard data.count <= 8192, let text = String(data: data, encoding: .utf8) else {
            throw VaultFailure.handover
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count == 1, lines[0].hasPrefix("AGE-SECRET-KEY-1") else { throw VaultFailure.handover }
        let key = Data((lines[0] + "\n").utf8)
        // Derive the public key from the secret; do not trust a comment in an imported file.
        let output = try programs.run("age-keygen", arguments: ["-y"], input: key)
        let recipient = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = Data(("# public key: " + recipient + "\n").utf8) + key
        _ = try Self.recipient(normalized)
        if let existing = try keychain.readIfPresent("age") {
            guard try Self.recipient(existing) == recipient else { throw VaultFailure.handover }
            return
        }
        try keychain.create(normalized, item: "age")     // a new key never takes the place of one (package 7)
    }

    static func recipient(_ identity: Data) throws -> String {
        guard let text = String(data: identity, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("# public key: ") }) else {
            throw VaultFailure.handover
        }
        let recipient = String(line.dropFirst(14))
        guard recipient.range(of: "^age1[0-9a-z]{58}$", options: .regularExpression) != nil else {
            throw VaultFailure.handover
        }
        return recipient
    }

    func open(_ ciphertext: Data) throws -> Data {
        try programs.run("age", arguments: ["--decrypt", "--identity", "/dev/fd/3"], input: ciphertext,
                         identity: keychain.read("age"))
    }

    func seal(_ data: Data, recipient: String) throws -> String {
        let sealed = try programs.run("age", arguments: ["--armor", "--recipient", recipient], input: data)
        guard let text = String(data: sealed, encoding: .utf8), text.hasPrefix("-----BEGIN AGE ENCRYPTED FILE-----\n") else {
            throw VaultFailure.handover
        }
        return text
    }
}
