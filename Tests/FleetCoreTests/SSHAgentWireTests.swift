import CryptoKit
import Foundation
import Testing
@testable import FleetCore

/// The SSH wire of a P-256 key (`SSHAgentWire`): the public line against OpenSSH's own `ssh-keygen`; the agent's
/// answers against OpenSSH's own `ssh-add`, on a socket of the test's own; and the bytes of r and s, of a login request
/// and of each refusal against RFC 4251, RFC 4252 and RFC 5656. No test reads a key of this Mac: each key is a key in
/// memory, made for the test.
@Suite(.timeLimit(.minutes(1)))
struct SSHAgentWireTests {
    typealias Wire = SSHAgentWire

    private func folder() throws -> URL {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("wire-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return made
    }

    /// One program of the system, to its end, with `SSH_AUTH_SOCK` when `agent` names a socket: its exit status and
    /// what it printed. While it runs, `serve` answers the connections that it makes to the agent.
    private func run(_ program: String, _ arguments: [String], agent: String? = nil,
                     serve: () throws -> Void = {}) throws -> (status: Int32, output: String) {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: program)
        child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_AUTH_SOCK"] = agent
        child.environment = environment
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        child.standardInput = FileHandle.nullDevice
        try child.run()
        try serve()
        let said = pipe.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        return (child.terminationStatus, String(decoding: said, as: UTF8.self))
    }

    /// A socket of the test's own that listens at `path`.
    private func listener(_ path: String) throws -> Int32 {
        let made = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(made >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(made, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0 && listen(made, 1) == 0)
        return made
    }

    /// The agent of the wire for the one connection that a program makes to `listener`: each message, as `next`
    /// frames it, gets `answer`, until the program closes the connection.
    private func answerOne(_ listener: Int32, _ answer: (Data) -> Data) throws {
        var waiting = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0)]
        try #require(poll(&waiting, 1, 20_000) == 1, "the program made no connection to the agent")
        let connection = accept(listener, nil, nil)
        try #require(connection >= 0)
        defer { close(connection) }
        var bytes = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(connection, &chunk, chunk.count)
            guard count > 0 else { return }
            bytes.append(contentsOf: chunk[0 ..< count])
            while case .message(let message, let size) = Wire.next(bytes) {
                bytes = Data(bytes.dropFirst(size))
                let reply = Array(answer(message))
                try #require(write(connection, reply, reply.count) == reply.count)
            }
        }
    }

    /// The data that ssh signs to log in (RFC 4252, section 7), with each field one that a test may change.
    private func login(_ blob: Data, user: String = "git", session: Data = Data(repeating: 7, count: 32),
                       request: UInt8 = 50, service: String = "ssh-connection", method: String = "publickey",
                       follows: UInt8 = 1, algorithm: String = SSHAgentWire.keyType, key: Data? = nil,
                       after: Data = Data()) -> Data {
        Wire.string(session) + Data([request]) + Wire.string(user) + Wire.string(service) + Wire.string(method) +
            Data([follows]) + Wire.string(algorithm) + Wire.string(key ?? blob) + after
    }

    // MARK: the public key

    /// Bug: a wrong public blob (the curve's name, the form of the point), so no verifier takes the key's line, and
    /// the key logs in nowhere and signs no commit that a release takes.
    @Test func thePublicLineIsTheOneThatSshKeygenGivesForTheKey() throws {
        let key = P256.Signing.PrivateKey()
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pem = folder.appendingPathComponent("public.pem")
        try key.publicKey.pemRepresentation.write(to: pem, atomically: true, encoding: .utf8)
        let given = try run("/usr/bin/ssh-keygen", ["-i", "-m", "PKCS8", "-f", pem.path])
        #expect(given.status == 0, "ssh-keygen said: \(given.output)")
        let theirs = given.output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Wire.publicLine(key.publicKey, comment: "") == theirs)
        #expect(Wire.publicLine(key.publicKey, comment: "founderizer-example.1") == theirs + " founderizer-example.1")
        let blob = try #require(Data(base64Encoded: String(theirs.split(separator: " ")[1])))
        #expect(Wire.publicBlob(key.publicKey) == blob)
        // the line and the blob read back to the key; a line of another type, a private key and a changed blob do not
        #expect(Wire.publicKey(line: theirs + " a comment")?.rawRepresentation == key.publicKey.rawRepresentation)
        // ssh-keygen's own line, with no comment and with its line break, as a file of it holds it
        #expect(Wire.publicKey(line: given.output)?.rawRepresentation == key.publicKey.rawRepresentation)
        #expect(given.output == theirs + "\n")
        #expect(Wire.publicKey(blob: blob)?.rawRepresentation == key.publicKey.rawRepresentation)
        let other = folder.appendingPathComponent("other")
        #expect(try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", other.path]).status == 0)
        #expect(Wire.publicKey(line: try String(contentsOf: other.appendingPathExtension("pub"), encoding: .utf8)) == nil)
        #expect(Wire.publicKey(line: try String(contentsOf: other, encoding: .utf8)) == nil)
        let compressed = Wire.string(Wire.keyType) + Wire.string("nistp256") +
            Wire.string(key.publicKey.compressedRepresentation)
        for changed in [blob + Wire.string("one more"), compressed, Data(blob.dropLast())] {
            #expect(Wire.publicKey(blob: changed) == nil)
        }
    }

    // MARK: the signature

    /// Bug: an r or an s with its high bit set and no zero byte before it, or with its first zero byte kept, so one
    /// login or commit in two, or one in about 128, fails by chance.
    @Test func rAndSAreMpintsOfTheFewestBytes() {
        let high = Data([0x80] + [UInt8](repeating: 1, count: 31))
        let low = Data([0x00, 0x7f] + [UInt8](repeating: 2, count: 30))
        let inner = Data([0, 0, 0, 33, 0, 0x80] + [UInt8](repeating: 1, count: 31) +
                         [0, 0, 0, 31, 0x7f] + [UInt8](repeating: 2, count: 30))
        #expect(Wire.signatureBlob(r: high, s: low) == Wire.string("ecdsa-sha2-nistp256") + Wire.string(inner))
        #expect(Wire.mpint(Data([0, 0, 0x81])) == Data([0, 0, 0, 2, 0, 0x81]))     // one zero byte stays
        #expect(Wire.mpint(Data([0, 0x01, 0x80])) == Data([0, 0, 0, 2, 0x01, 0x80]))
        #expect(Wire.mpint(Data([0, 0])) == Data([0, 0, 0, 0]))                    // zero is the empty string
        #expect(Wire.uint32(0x0102_0304) == Data([1, 2, 3, 4]))
        #expect(Wire.string("ab") == Data([0, 0, 0, 2, 0x61, 0x62]))
    }

    // MARK: the agent

    /// Bug: the answer to message 11 is not in the form that ssh reads, so ssh sees no key and each login with the
    /// key fails; or the agent signs bytes that are no login (ssh-add -T asks it to sign random bytes).
    @Test func sshAddListsTheOneKeyOfTheAgentAndGetsNoSignatureOfBytesThatAreNoLogin() throws {
        let key = P256.Signing.PrivateKey()
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("a").path
        let socket = try listener(path)
        defer { close(socket) }
        let line = Wire.publicLine(key.publicKey, comment: "founderizer-example.1")
        var signed = 0
        func agent(_ message: Data) -> Data {
            Wire.answer(to: message, key: key.publicKey, comment: "founderizer-example.1", user: "git") {
                signed += 1
                return try key.signature(for: $0)
            }
        }
        let listed = try run("/usr/bin/ssh-add", ["-L"], agent: path) { try answerOne(socket, agent) }
        #expect(listed.status == 0, "ssh-add -L said: \(listed.output)")
        #expect(listed.output == line + "\n")
        let file = folder.appendingPathComponent("key.pub")
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
        let tested = try run("/usr/bin/ssh-add", ["-T", file.path], agent: path) { try answerOne(socket, agent) }
        #expect(tested.status != 0, "ssh-add -T got a signature of bytes that are no login: \(tested.output)")
        #expect(tested.output.contains("agent refused operation"), "ssh-add -T said: \(tested.output)")
        #expect(signed == 0)
    }

    /// Bug: a login key signs a commit, a login as another user or a login with another key; or its answer is not
    /// the signature of the data in the form that a server takes.
    @Test func theAgentSignsOnlyALoginWithItsKeyAsItsUser() throws {
        let key = P256.Signing.PrivateKey()
        let blob = Wire.publicBlob(key.publicKey)
        var signed = 0
        func asked(_ data: Data, key keyBlob: Data? = nil, flags: Data = Wire.uint32(0),
                   sign: ((Data) throws -> P256.Signing.ECDSASignature)? = nil) -> Data {
            let message = Data([13]) + Wire.string(keyBlob ?? blob) + Wire.string(data) + flags
            return Wire.answer(to: message, key: key.publicKey, comment: "", user: "git") {
                signed += 1
                return try (sign ?? { try key.signature(for: $0) })($0)
            }
        }
        // a login with the key as git, by both of OpenSSH's methods: the signature of the data, as r and s
        let host = Wire.string("ssh-ed25519") + Wire.string(Data(repeating: 9, count: 32))
        for data in [login(blob), login(blob, method: "publickey-hostbound-v00@openssh.com", after: Wire.string(host))] {
            let answer = asked(data)
            var reader = Wire.Reader(answer)
            let length = reader.uint32(), type = reader.byte(), field = reader.string()
            #expect(length == UInt32(answer.count - 4) && type == 14 && reader.atEnd)
            var signature = Wire.Reader(try #require(field))
            let algorithm = signature.string(), pair = signature.string()
            #expect(algorithm == Data("ecdsa-sha2-nistp256".utf8) && signature.atEnd)
            var numbers = Wire.Reader(try #require(pair))
            let r = numbers.string(), s = numbers.string()
            #expect(numbers.atEnd)
            func raw(_ number: Data) -> Data { Data(repeating: 0, count: max(0, 32 - number.count)) + number.suffix(32) }
            let made = try P256.Signing.ECDSASignature(rawRepresentation: raw(try #require(r)) + raw(try #require(s)))
            #expect(key.publicKey.isValidSignature(made, for: data))
        }
        #expect(signed == 2)
        // each other request gets failure, and the key signs none of it
        let other = Wire.publicBlob(P256.Signing.PrivateKey().publicKey)
        let commit = Data("SSHSIG".utf8) + Wire.string("git") + Wire.string(Data()) + Wire.string("sha512") +
            Wire.string(Data(SHA512.hash(data: Data("tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n".utf8))))
        let refused: [(String, Data)] = [
            ("the signed bytes of a commit", asked(commit)),
            ("a login as another user", asked(login(blob, user: "root"))),
            ("a login with another key", asked(login(blob, key: other))),
            ("a message for another key", asked(login(blob), key: other)),
            ("another algorithm", asked(login(blob, algorithm: "ecdsa-sha2-nistp384"))),
            ("another service", asked(login(blob, service: "ssh-userauth"))),
            ("no user-auth request", asked(login(blob, request: 51))),
            ("no signature follows", asked(login(blob, follows: 0))),
            ("another method", asked(login(blob, method: "hostbased"))),
            ("the second method with no host key", asked(login(blob, method: "publickey-hostbound-v00@openssh.com"))),
            ("one byte more", asked(login(blob) + Data([0]))),
            ("an empty session id", asked(login(blob, session: Data()))),
            ("no flags", asked(login(blob), flags: Data())),
            ("random bytes", asked(Data((0 ..< 64).map { _ in UInt8.random(in: 0 ... 255) }))),
        ]
        for (what, answer) in refused {
            #expect(answer == Wire.failure, "\(what) got \(answer.count) bytes")
        }
        // each shorter part of a whole request, from no byte to all but its last one, is no request
        let whole = Data([13]) + Wire.string(blob) + Wire.string(login(blob)) + Wire.uint32(0)
        for count in 0 ..< whole.count {
            let answer = Wire.answer(to: whole.prefix(count), key: key.publicKey, comment: "", user: "git") {
                signed += 1
                return try key.signature(for: $0)
            }
            #expect(answer == Wire.failure, "the first \(count) bytes of a request got \(answer.count) bytes")
        }
        #expect(signed == 2)
        // a key that does not sign (the Secure Enclave refuses), or a signature of another key, gives failure
        struct Refused: Error {}
        #expect(asked(login(blob), sign: { _ in throw Refused() }) == Wire.failure)
        let wrong = P256.Signing.PrivateKey()
        #expect(asked(login(blob), sign: { try wrong.signature(for: $0) }) == Wire.failure)
        #expect(Wire.answer(to: Data([13]) + Wire.string(blob) + Wire.string(login(blob, user: "")) + Wire.uint32(0),
                            key: key.publicKey, comment: "", user: "") { try key.signature(for: $0) } == Wire.failure)
    }

    /// Bug: the agent answers a message that is not its own (it adds a key that then signs, or locks), or it reads a
    /// message of any length into memory.
    @Test func eachOtherMessageGetsFailureAndOneOver256KiBClosesTheConnection() throws {
        let key = P256.Signing.PrivateKey()
        let blob = Wire.publicBlob(key.publicKey)
        var signed = 0
        func answer(_ message: Data) -> Data {
            Wire.answer(to: message, key: key.publicKey, comment: "founderizer-example.1", user: "git") {
                signed += 1
                return try key.signature(for: $0)
            }
        }
        #expect(Wire.failure == Data([0, 0, 0, 1, 5]))
        #expect(answer(Data([11])) == Wire.string(Data([12]) + Wire.uint32(1) + Wire.string(blob) +
                                                  Wire.string("founderizer-example.1")))
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        let fields: Data = Wire.string(Wire.keyType) + Wire.string("nistp256") + Wire.string(point)
        let added: Data = fields + Wire.string(Data(repeating: 1, count: 32))
        let others: [(String, Data)] = [
            ("a key to add", Data([17]) + added),
            ("a key to add with a rule", Data([25]) + added + Data([1]) + Wire.uint32(60)),
            ("all keys to remove", Data([19])),
            ("a lock", Data([22]) + Wire.string("words")),
            ("an extension, as ssh's session-bind", Data([27]) + Wire.string("session-bind@openssh.com")),
            ("the list of keys with a byte more", Data([11, 0])),
            ("an answer of an agent", Data([12])),
            ("a signature", Data([14])),
            ("no type", Data()),
        ]
        for (what, message) in others {
            #expect(answer(message) == Wire.failure, "\(what)")
        }
        #expect(signed == 0)
        // the frames: a message only when it is all there, the first one first, and one over the limit closes
        #expect(Wire.next(Data()) == .partial)
        #expect(Wire.next(Data([0, 0, 0])) == .partial)
        #expect(Wire.next(Wire.uint32(5) + Data([11])) == .partial)
        #expect(Wire.next(Wire.string(Data([11])) + Wire.string(Data([13]))) == .message(Data([11]), size: 5))
        let largest = Wire.largest
        #expect(Wire.next(Wire.uint32(UInt32(largest))) == .partial)
        #expect(Wire.next(Wire.uint32(UInt32(largest + 1))) == .tooLong)
        #expect(Wire.next(Wire.uint32(UInt32.max)) == .tooLong)
        let whole = Data([13]) + Data(count: largest - 1)
        #expect(Wire.next(Wire.string(whole)) == .message(whole, size: largest + 4))
    }
}
