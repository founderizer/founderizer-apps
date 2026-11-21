import CryptoKit
import Foundation
import Testing
@testable import FleetCore

/// **A stand-in for a hub that asks the owner's Mac for its key, and for the claim's listener**, which opens no port:
/// it answers each request of a session whose configuration holds it, as `hub.py` `owner_allowed` and
/// `ui_owner_key` and `hubsetup.py` `ClaimHandler` do. Each test has its own hub, found by the host of its address.
final class KeyedHub: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        /// The SHA-256 that the hub keeps, or nil for a hub from before the key.
        var sha: String?
        /// The one-time value of a registration and the path that the hub names for it.
        var proof = "p" + String(repeating: "A", count: 42)
        var proofFile: String? = "/home/fleet/.fleet/owner-key.proof"
        /// A claim's listener keeps the SHA-256 that comes with the code.
        var keeps = true
        /// A claim's listener refuses the code, and so keeps nothing.
        var refusesClaim = false
        /// The next answers that do not arrive, after the hub did what the request asked.
        var loses = 0
        var seen: [(path: String, bearer: String?, claimSha: String?, body: [String: String])] = []
    }
    nonisolated(unsafe) private static var hubs: [String: State] = [:]
    private static let lock = NSLock()

    static func hub(_ host: String) -> State {
        lock.lock(); defer { lock.unlock() }
        if let state = hubs[host] { return state }
        let state = State()
        hubs[host] = state
        return state
    }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KeyedHub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private func answer(_ status: Int, _ json: String, headers: [String: String] = [:], changed: Bool = false) {
        let state = Self.hub(request.url?.host ?? "")
        if changed, state.loses > 0 {
            state.loses -= 1
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let all = headers.merging(["Content-Type": "application/json"]) { old, _ in old }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: all)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func startLoading() {
        let url = request.url!, state = Self.hub(url.host ?? "")
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(buffer, count: count)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: bytes) as? [String: String]) ?? [:]
        let sent = request.value(forHTTPHeaderField: "Authorization")
        let bearer = sent.flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        let claimSha = request.value(forHTTPHeaderField: OwnerMacKey.claimHeader)
        state.lock.lock()
        defer { state.lock.unlock() }
        state.seen.append((url.path, bearer, claimSha, body))
        if url.path == "/claim" {
            if state.refusesClaim { return answer(403, "not the code") }
            if state.keeps { state.sha = claimSha }
            return answer(200, "claimed", headers: state.keeps && claimSha != nil ? [OwnerMacKey.claimKept: "kept"] : [:],
                          changed: true)
        }
        if url.path == "/ui/owner/key" {
            guard let proof = body["proof"] else {
                let file = state.proofFile.map { "\"\($0)\"" } ?? "null"
                return answer(200, #"{"registered": false, "proof_file": \#(file), "expires": 1}"#)
            }
            guard proof == state.proof, let sha = body["sha256"] else {
                return answer(403, #"{"error": "not the value", "auth": "owner_proof_mismatch"}"#)
            }
            state.sha = sha
            return answer(200, #"{"registered": true, "since": 1}"#, changed: true)
        }
        guard let sha = state.sha else {
            return bearer == nil ? answer(200, "{}") : answer(403, #"{"error": "send no bearer", "auth": "key_not_expected"}"#)
        }
        guard let bearer else { return answer(403, #"{"error": "no key", "auth": "owner_key_required"}"#) }
        return OwnerMacKey.digest(bearer) == sha ? answer(200, "{}")
            : answer(403, #"{"error": "another key", "auth": "owner_key_mismatch"}"#)
    }
}

/// An address of its own for each hub of a test, written as a number of the private network's range: the key's file
/// of a hub that is called by a name is found by a lookup, and no test asks a resolver.
enum TestHub {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last = 0
    static func address() -> String {
        let number = lock.withLock { last += 1; return last }
        return "100.66.\(number / 250 % 250).\(number % 250 + 2)"
    }
}

/// This Mac's own key for a hub: where it is kept, when a call carries it, and how the Mac registers it.
struct OwnerMacKeyTests {
    private let home: URL
    private let host = TestHub.address()
    private var hub: URL { URL(string: "http://\(host):8765")! }
    private var state: KeyedHub.State { KeyedHub.hub(host) }
    private static let key = "k" + String(repeating: "b", count: 42)
    private static let other = "k" + String(repeating: "c", count: 42)

    init() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("owner-mac-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    /// A hub that is written as a number needs no lookup, and a test never asks the system's.
    private static let noLookup: @Sendable (String) -> String? = { host in
        Issue.record("a lookup of \(host)")
        return nil
    }

    private func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    private func status(_ answer: (Data, URLResponse)) -> Int? { (answer.1 as? HTTPURLResponse)?.statusCode }

    private func read(path: String = "ui/state") async throws -> (Data, URLResponse) {
        try await KeyedHub.session.hubData(for: URLRequest(url: hub.appendingPathComponent(path)), home: home, lookup: Self.noLookup)
    }

    // ------------------------------------------------------------ the file

    /// The same name in `owner_mcp.py` (`owner_key_file`), in `hubsetup.py`'s claim script and in `founderizer-cli`.
    @Test func theFileOfAHubIsItsHostAndItsPort() {
        #expect(OwnerMacKey.name(hub: URL(string: "http://100.64.0.9:8765")!) == "100.64.0.9_8765")
        #expect(OwnerMacKey.name(hub: URL(string: "http://100.64.0.9:8765/")!) == "100.64.0.9_8765")
        #expect(OwnerMacKey.name(hub: URL(string: "http://Hub.Example.COM:9000/ui/state?db=1")!) == "hub.example.com_9000")
        #expect(OwnerMacKey.name(hub: URL(string: "http://hub.example")!) == "hub.example_80")
        #expect(OwnerMacKey.name(hub: URL(string: "https://hub.example")!) == "hub.example_443")
        #expect(OwnerMacKey.name(hub: URL(string: "http://[fd7a:115c:a1e0::1]:8765")!) == "fd7a-115c-a1e0--1_8765")
        #expect(OwnerMacKey.name(hub: URL(string: "file:///etc/passwd")!) == nil)
        #expect(OwnerMacKey.file(hub: hub, home: home)?.path
                == home.appendingPathComponent(".founderizer/owner-keys/\(host)_8765").path)
        #expect(OwnerMacKey.file(hub: hub, home: nil) == nil)          // a real iPhone: no such folder
        // A test run reads no key of the user that runs it: only a test that gives a home has one.
        #expect(OwnerMacKey.inTestRun && OwnerMacKey.home == nil)
        #expect(OwnerMacKey.file(hub: hub) == nil)
        #expect(OwnerMacKey.authorized(URLRequest(url: hub)).value(forHTTPHeaderField: "Authorization") == nil)
        // A hub that is called by a name has the file of its number, and no file while the name has no number.
        let byName = URL(string: "http://hub-1.tail1234.ts.net:8765")!
        #expect(OwnerMacKey.file(hub: byName, home: home, lookup: { _ in "100.64.0.9" })?.lastPathComponent == "100.64.0.9_8765")
        #expect(OwnerMacKey.file(hub: byName, home: home, lookup: { _ in "FD7A:115C:A1E0::1" })?.lastPathComponent == "fd7a-115c-a1e0--1_8765")
        #expect(OwnerMacKey.file(hub: byName, home: home, lookup: { _ in nil }) == nil)
        #expect(OwnerMacKey.file(hub: byName, home: home, lookup: { _ in "not an address" }) == nil)
    }

    @Test func aNewKeyIs32RandomBytesAndTheHubGetsOnlyItsSha() throws {
        let key = try OwnerMacKey.make()
        #expect(key.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil)
        #expect(try OwnerMacKey.make() != key)
        #expect(try OwnerMacKey.make(random: { Data(repeating: 0xFB, count: $0) }) == String(repeating: "-_v7", count: 10) + "-_s")
        // Python: hashlib.sha256(b"abc").hexdigest()
        #expect(OwnerMacKey.digest("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func theKeyIsKeptForThisUserAloneAndReadBack() throws {
        #expect(OwnerMacKey.read(hub: hub, home: home) == nil)
        try OwnerMacKey.keep(Self.key, hub: hub, home: home)
        let file = try #require(OwnerMacKey.file(hub: hub, home: home))
        #expect(OwnerMacKey.read(hub: hub, home: home) == Self.key)
        #expect(mode(file) == 0o600)
        #expect(mode(file.deletingLastPathComponent()) == 0o700)
        #expect(try String(contentsOf: file, encoding: .utf8) == Self.key + "\n")
        // A second key takes its place, and nothing else is left in the folder.
        try OwnerMacKey.keep(Self.other, hub: hub, home: home)
        #expect(OwnerMacKey.read(hub: hub, home: home) == Self.other)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == [file.lastPathComponent])
        // The key of another hub, and of the same host on another port, is another file.
        #expect(OwnerMacKey.read(hub: URL(string: "http://\(host):9000")!, home: home) == nil)
        #expect(throws: OwnerMacKey.NotKept.self) { try OwnerMacKey.keep("short", hub: hub, home: home) }
        #expect(throws: OwnerMacKey.NotKept.self) { try OwnerMacKey.keep(Self.key, hub: hub, home: nil) }
    }

    @Test func aFileThatHoldsNoKeyIsNoKey() throws {
        let file = try #require(OwnerMacKey.file(hub: hub, home: home))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for text in ["", "short", "two words that are no key at all, with spaces", String(repeating: "a", count: 300),
                     Self.key + "\nBearer " + Self.other] {
            try Data(text.utf8).write(to: file)
            #expect(OwnerMacKey.read(hub: hub, home: home) == nil, "\(text.prefix(20))")
        }
    }

    // ------------------------------------------------------------ the key on a call

    @Test func aCallCarriesTheKeyOfItsOwnHubAndOfNoOther() throws {
        try OwnerMacKey.keep(Self.key, hub: hub, home: home)
        let request = URLRequest(url: hub.appendingPathComponent("ui/state"))
        #expect(OwnerMacKey.authorized(request, home: home).value(forHTTPHeaderField: "Authorization") == "Bearer " + Self.key)
        for elsewhere in ["http://\(host):9000/ui/state", "http://other.example.com:8765/ui/state",
                          "https://api.github.com/app", "https://\(host)/ui/state"] {
            let other = URLRequest(url: URL(string: elsewhere)!)
            #expect(OwnerMacKey.authorized(other, home: home, lookup: { _ in nil }).value(forHTTPHeaderField: "Authorization") == nil, "\(elsewhere)")
        }
        // A name that is another address gets no key, and a name that is this hub's address gets this hub's key.
        let named = URLRequest(url: URL(string: "http://other.example.com:8765/ui/state")!)
        #expect(OwnerMacKey.authorized(named, home: home, lookup: { _ in "100.64.0.99" }).value(forHTTPHeaderField: "Authorization") == nil)
        let host = host
        #expect(OwnerMacKey.authorized(named, home: home, lookup: { _ in host }).value(forHTTPHeaderField: "Authorization") == "Bearer " + Self.key)
        // A request with a credential of its own keeps it: a phone's read carries the phone's key.
        var phone = request
        phone.setValue("Bearer phone-key", forHTTPHeaderField: "Authorization")
        #expect(OwnerMacKey.authorized(phone, home: home).value(forHTTPHeaderField: "Authorization") == "Bearer phone-key")
        #expect(OwnerMacKey.authorized(request, home: nil).value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func aHubThatHasTheKeyTakesTheCallAndRefusesTheAddressAlone() async throws {
        state.sha = OwnerMacKey.digest(Self.key)
        // No key on this Mac: the hub refuses, and the app knows why.
        #expect(status(try await read()) == 403)
        #expect(OwnerMacKey.refused(hub: hub) == .required)
        try OwnerMacKey.keep(Self.other, hub: hub, home: home)
        #expect(status(try await read()) == 403)
        #expect(OwnerMacKey.refused(hub: hub) == .mismatch)
        try OwnerMacKey.keep(Self.key, hub: hub, home: home)
        #expect(status(try await read()) == 200)
        #expect(OwnerMacKey.refused(hub: hub) == nil)
        #expect(state.seen.map(\.bearer) == [nil, Self.other, Self.key])        // each call went once
    }

    @Test func aHubFromBeforeTheKeyGetsTheCallAgainWithNoKeyAndThenNoKeyAtAll() async throws {
        try OwnerMacKey.keep(Self.key, hub: hub, home: home)
        #expect(!OwnerMacKey.notExpected(hub: hub, home: home))
        #expect(status(try await read()) == 200)
        #expect(state.seen.map(\.bearer) == [Self.key, nil])
        #expect(OwnerMacKey.notExpected(hub: hub, home: home))
        #expect(OwnerMacKey.refused(hub: hub) == nil)
        #expect(status(try await read()) == 200)
        #expect(state.seen.map(\.bearer) == [Self.key, nil, nil])
        // A new key of this Mac is a key that the hub has not refused: it goes.
        try OwnerMacKey.keep(Self.other, hub: hub, home: home)
        #expect(!OwnerMacKey.notExpected(hub: hub, home: home))
        state.sha = OwnerMacKey.digest(Self.other)
        #expect(status(try await read()) == 200)
        #expect(state.seen.last?.bearer == Self.other)
    }

    /// In the moment of a registration, reads that left with no key come back refused after the key is kept. They say
    /// nothing of the new key: recorded, they would make the app register a second time.
    @Test func aRefusalOfARequestFromBeforeTheKeyChangedIsNotThisKeysRefusal() throws {
        let url = hub.appendingPathComponent("ui/state")
        let refused = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
        let required = Data(#"{"auth": "owner_key_required"}"#.utf8), mismatch = Data(#"{"auth": "owner_key_mismatch"}"#.utf8)
        var old = URLRequest(url: url)
        // It left with no key, and the Mac has one now.
        try OwnerMacKey.keep(Self.key, hub: hub, home: home)
        OwnerMacKey.took(old, ours: false, answer: refused, required, home: home)
        #expect(OwnerMacKey.refused(hub: hub) == nil)
        // It left with the key from before, and the Mac has another one now.
        old.setValue("Bearer " + Self.other, forHTTPHeaderField: "Authorization")
        OwnerMacKey.took(old, ours: true, answer: refused, mismatch, home: home)
        #expect(OwnerMacKey.refused(hub: hub) == nil)
        // The key that the Mac has now, refused: that is this key's refusal. A new key takes the mark away.
        var now = URLRequest(url: url)
        now.setValue("Bearer " + Self.key, forHTTPHeaderField: "Authorization")
        OwnerMacKey.took(now, ours: true, answer: refused, mismatch, home: home)
        #expect(OwnerMacKey.refused(hub: hub) == .mismatch)
        try OwnerMacKey.keep(Self.other, hub: hub, home: home)
        #expect(OwnerMacKey.refused(hub: hub) == nil)
    }

    @Test func aKeyThatIsNotOursIsNeverSentAgainWithout() async throws {
        // A phone's own key that the hub refuses as not expected: the request is the phone's, and it goes once.
        var request = URLRequest(url: hub.appendingPathComponent("ui/state"))
        request.setValue("Bearer phone-key", forHTTPHeaderField: "Authorization")
        let answer = try await KeyedHub.session.hubData(for: request, home: home)
        #expect(status(answer) == 403)
        #expect(state.seen.map(\.bearer) == ["phone-key"])
        #expect(OwnerMacKey.refusal(answer.1, answer.0) == .notExpected)
    }

    @Test func onlyA403ThatNamesTheKeyIsARefusalOfTheKey() {
        let url = hub
        func response(_ status: Int) -> HTTPURLResponse { HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)! }
        #expect(OwnerMacKey.refusal(response(403), Data(#"{"auth": "owner_key_required"}"#.utf8)) == .required)
        #expect(OwnerMacKey.refusal(response(403), Data(#"{"auth": "owner_key_mismatch"}"#.utf8)) == .mismatch)
        #expect(OwnerMacKey.refusal(response(403), Data(#"{"auth": "key_not_expected"}"#.utf8)) == .notExpected)
        #expect(OwnerMacKey.refusal(response(403), Data(#"{"auth": "device_key_required"}"#.utf8)) == nil)
        #expect(OwnerMacKey.refusal(response(403), Data(#"{"error": "not the owner's machine"}"#.utf8)) == nil)
        #expect(OwnerMacKey.refusal(response(200), Data(#"{"auth": "owner_key_required"}"#.utf8)) == nil)
        #expect(OwnerMacKey.refusal(response(403), Data("<html>".utf8)) == nil)
    }

    // ------------------------------------------------------------ the registration over SSH

    @Test func theMacReadsOnlyAFileOfTheHubsOwnNameAtAPlainPath() {
        let good = "/home/fleet/.fleet/owner-key.proof"
        #expect(OwnerMacKeyRegistration.path(good) == good)
        #expect(OwnerMacKeyRegistration.path("/private/var/folders/by/T/x-1/records/owner-key.proof") != nil)
        for bad in [nil, "", "owner-key.proof", "~/.fleet/owner-key.proof", "/etc/shadow", "/home/fleet/.fleet/owner-key.json",
                    "/home/fleet/../root/owner-key.proof", "/home/./fleet/owner-key.proof", "/home//fleet/owner-key.proof",
                    "/home/fleet/.fleet/owner-key.proof/", "/home/fleet/owner-key.proof; rm -rf /", "/home/fl eet/owner-key.proof",
                    "/home/$(id)/owner-key.proof", "/home/fleet/'x'/owner-key.proof", "/home/fleet/owner-key.proof\n/etc/shadow",
                    "/" + String(repeating: "a", count: 600) + "/owner-key.proof"] as [String?] {
            #expect(OwnerMacKeyRegistration.path(bad) == nil, "\(bad ?? "nil")")
        }
    }

    /// The program as `/bin/sh` runs it here, as this user: what it prints. `tools`: a folder of programs that stand
    /// before the system's own in its `PATH`.
    private func runs(_ path: String, tools: URL? = nil) throws -> String {
        let shell = Process(), out = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", OwnerMacKeyRegistration.program(path: path)]
        if let tools { shell.environment = ["PATH": tools.path + ":/usr/bin:/bin"] }
        shell.standardOutput = out
        shell.standardError = out
        try shell.run()
        shell.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// A folder with programs of these names, each a shell script of the given lines.
    private func tools(_ programs: [String: String]) throws -> URL {
        let folder = home.appendingPathComponent("tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, lines) in programs {
            let file = folder.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + lines + "\n").utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return folder
    }

    /// **The program is run, and not only read**: a file of this user gives its value after the mark; a file of root
    /// gives none, whatever it holds; and a link gives what its own owner can read, never more.
    @Test func theProgramReadsTheFileAsItsOwnerAndNeverRootsFile() throws {
        let value = String(repeating: "aB3_-", count: 8) + "xyz"
        let file = home.appendingPathComponent("owner-key.proof")
        try Data((value + "\n").utf8).write(to: file)
        #expect(try runs(file.path).hasPrefix("founderizer-proof:" + value + "\nfounderizer-addresses:"))
        #expect(OwnerMacKeyRegistration.value(try runs(file.path)) == value)
        // Its last line is this machine's own addresses, as the program finds them here.
        #expect(try runs(file.path).hasSuffix("\n") && runs(file.path).split(separator: "\n").count == 2)
        #expect(OwnerMacKeyRegistration.addresses(try runs(file.path)).contains("127.0.0.1"))
        // At most 64 bytes of it.
        try Data(String(repeating: "x", count: 500).utf8).write(to: file)
        #expect(try runs(file.path).hasPrefix("founderizer-proof:" + String(repeating: "x", count: 64) + "\nfounderizer-addresses:"))
        // A file of root: nothing is read, and no mark is printed.
        #expect(try runs("/etc/hosts") == "")
        #expect(try runs("/etc/master.passwd") == "")
        // A link of this user to a file of root: the program reads as the link's owner, who is this user here, so it
        // gets what this user gets and no more (a file that this user cannot read gives no value).
        let link = home.appendingPathComponent("link/owner-key.proof")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/master.passwd")
        #expect(OwnerMacKeyRegistration.value(try runs(link.path)) == nil)
        // A path that is not there.
        #expect(try runs(home.appendingPathComponent("none/owner-key.proof").path) == "")
    }

    /// **As another user than the file's owner** (root on the hub's server, when the hub runs as a user of its own):
    /// the read goes through `sudo -n -u` with the owner's number, and what `sudo` writes while it reads stands
    /// nowhere between the mark and the value. Root is the number 0, whatever name a server gives that user.
    @Test func theProgramReadsThroughSudoAsTheOwnersNumberAndRootIsTheNumberZero() throws {
        let value = String(repeating: "aB3_-", count: 8) + "xyz"
        let file = home.appendingPathComponent("owner-key.proof")
        try Data((value + "\n").utf8).write(to: file)
        let said = home.appendingPathComponent("sudo.said")
        // This user is somebody else here (`id`), and `sudo` complains before it runs what it was given.
        let other = try tools([
            "id": "echo 4242",
            "sudo": "echo 'sudo: unable to resolve host hub-1: Name or service not known' >&2\n"
                + "printf '%s\\n' \"$*\" > '\(said.path)'\n"
                + "[ \"$1\" = -n ] && [ \"$2\" = -u ] && [ \"$4\" = -- ] || exit 9\nshift 4\nexec \"$@\"",
        ])
        #expect(try runs(file.path, tools: other).hasPrefix("founderizer-proof:" + value + "\nfounderizer-addresses:"))
        #expect(OwnerMacKeyRegistration.addresses(try runs(file.path, tools: other)).contains("127.0.0.1"))
        #expect(try String(contentsOf: said, encoding: .utf8) == "-n -u #\(getuid()) -- head -c 64 -- \(file.path)\n")
        // A `sudo` that may not: no value, and the mark alone is no value.
        let refused = try tools(["id": "echo 4242", "sudo": "echo 'sudo: a password is required' >&2\nexit 1"])
        #expect(try runs(file.path, tools: refused).hasPrefix("founderizer-proof:\nfounderizer-addresses:"))
        #expect(OwnerMacKeyRegistration.value(try runs(file.path, tools: refused)) == nil)
        // A `sudo` that writes to the program's own output: it is no value of the right shape.
        let loud = try tools(["id": "echo 4242", "sudo": "echo 'We trust you have received the usual lecture.'\nshift 4\nexec \"$@\""])
        #expect(OwnerMacKeyRegistration.value(try runs(file.path, tools: loud)) == nil)
        // The owner is the number 0: nothing is read, whatever name that user has, and nobody is asked.
        try? FileManager.default.removeItem(at: said)
        let root = try tools(["stat": "echo 0", "sudo": "printf called > '\(said.path)'"])
        #expect(try runs(file.path, tools: root) == "")
        #expect(!FileManager.default.fileExists(atPath: said.path))
    }

    @Test func theProgramAsksWhoOwnsTheFileAndNeverReadsAsRoot() {
        let program = OwnerMacKeyRegistration.program(path: "/home/fleet/.fleet/owner-key.proof")
        #expect(program.hasPrefix("f='/home/fleet/.fleet/owner-key.proof'; u=$(stat -c %u -- \"$f\" 2>/dev/null || stat -f %u -- \"$f\" 2>/dev/null); "))
        #expect(program.contains("[ -n \"$u\" ] && [ \"$u\" != 0 ] || exit 1; "))
        #expect(program.contains("v=$(if [ \"$(id -u)\" = \"$u\" ]; then head -c 64 -- \"$f\"; else sudo -n -u \"#$u\" -- head -c 64 -- \"$f\"; fi 2>/dev/null); "))
        #expect(program.contains("printf 'founderizer-proof:%s\\n' \"$v\"; "))
        #expect(program.hasSuffix("a=$(PATH=\"$PATH:/usr/sbin:/sbin\"; { ip -o addr 2>/dev/null || ifconfig 2>/dev/null; } | tr '\\n' ' '); printf 'founderizer-addresses:%s\\n' \"$a\""))
        #expect(!program.contains("\n"))
        // As root on the hub's server it goes through `sudo -i`, whose login shell reads a "$name": the installer's
        // own words for such a program carry it whole (`InstallPlan.throughSudo`, `RootThroughSudoTests`).
        let target = InstallTarget(host: "100.64.0.9", user: "admin", becomeRoot: true)
        let root = OwnerMacKeyRegistration.arguments(target: target, program: program, asRoot: true)
        #expect(root.last?.hasPrefix("sudo -n -i -- /bin/sh -c ") == true)
        #expect(root.last?.contains("$u") == false)
        #expect(root.contains("StrictHostKeyChecking=yes") && !root.contains("StrictHostKeyChecking=accept-new"))
        let own = OwnerMacKeyRegistration.arguments(target: target, program: program, asRoot: false)
        #expect(own.last == program)                                    // as the login user: no sudo around it
        #expect(own.contains("StrictHostKeyChecking=yes") && own.contains("ClearAllForwardings=yes"))
        // The same two reads with the app's own key, once a run with it alone got in: no configuration, the login
        // read still as the login user, the root read still through sudo (bug: app mode puts sudo around the login
        // read, or drops it from the root read).
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ssh-ledger-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = SSHKeyLedger(folder: folder)
        ledger.recordPlain(SSHKeyLedger.Account(address: "100.64.0.9", user: "admin", port: 22), now: 1_794_000_000)
        var keyed = target
        keyed.identityFile = AppSSHKey.path()
        let login = OwnerMacKeyRegistration.arguments(target: keyed, program: program, asRoot: false, ledger: ledger)
        let asRoot = OwnerMacKeyRegistration.arguments(target: keyed, program: program, asRoot: true, ledger: ledger)
        #expect(login.prefix(2) == ["-F", "/dev/null"] && login.last == program && login.contains("StrictHostKeyChecking=yes"))
        #expect(asRoot.prefix(2) == ["-F", "/dev/null"] && asRoot.last == root.last)
    }

    @Test func onlyAValueOfTheRightShapeAfterTheMarkGoesBackToTheHub() {
        let value = String(repeating: "aB3_-", count: 8) + "xyz", mark = "founderizer-proof:"
        #expect(OwnerMacKeyRegistration.value(mark + value + "\n") == value)
        // Lines of sudo, of a login shell and of SSH itself around it change nothing.
        #expect(OwnerMacKeyRegistration.value("sudo: unable to resolve host hub-1: Name or service not known\n" + mark + value + "\n") == value)
        #expect(OwnerMacKeyRegistration.value("** WARNING: connection is not using a post-quantum key exchange\r\n" + mark + value + "\r\nlogout\n") == value)
        for other in ["", value, value + "\n", mark, mark + "\n" + value, mark + "root:$6$salt$hash:19000:0:99999:7:::",
                      mark + value + "x", mark + String(value.dropLast()), mark + value + " " + value,
                      mark + "-----BEGIN OPENSSH PRIVATE KEY-----", mark + value + "\n" + mark + "something else"] {
            #expect(OwnerMacKeyRegistration.value(other) == nil, "\(other.prefix(30))")
        }
    }

    @Test func theServersOwnAddressesAreReadFromWhatItsProgramPrinted() {
        let linux = "1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever preferred_lft forever 1: lo    inet6 ::1/128 scope host \\       valid_lft forever "
            + "2: enp0s1    inet 192.0.2.28/24 metric 100 brd 192.0.2.255 scope global dynamic enp0s1 3: tailscale0    inet 100.64.0.9/32 scope global tailscale0 "
            + "3: tailscale0    inet6 FD7A:115C:A1E0::1/128 scope global "
        let mac = "lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384 \tinet 127.0.0.1 netmask 0xff000000 \tinet6 ::1 prefixlen 128 \tinet6 fe80::1%lo0 prefixlen 64 scopeid 0x1 "
            + "en0: flags=8863<UP> \tether 00:00:5e:00:53:01 \tinet 192.0.2.5 netmask 0xffffff00 broadcast 192.0.2.255 utun3: \tinet 100.64.0.10 --> 100.64.0.10 netmask 0xffffffff "
        let proof = "founderizer-proof:" + String(repeating: "z", count: 43) + "\n"
        #expect(OwnerMacKeyRegistration.addresses(proof + "founderizer-addresses:" + linux + "\n")
                == ["127.0.0.1", "::1", "192.0.2.28", "100.64.0.9", "fd7a:115c:a1e0::1"])
        #expect(OwnerMacKeyRegistration.addresses(proof + "founderizer-addresses:" + mac + "\nlogout\n")
                == ["127.0.0.1", "::1", "fe80::1", "192.0.2.5", "100.64.0.10"])
        // Only the line after the program's own last mark: words before it name no address of the server.
        #expect(OwnerMacKeyRegistration.addresses("inet 100.64.0.99 said somebody\n" + proof + "founderizer-addresses:\n").isEmpty)
        #expect(OwnerMacKeyRegistration.addresses(proof).isEmpty)
        #expect(OwnerMacKeyRegistration.addresses("founderizer-addresses:inet not-an-address inet 999.1.1.1 ether 00:00:5e:00:53:01\n").isEmpty)
        #expect(OwnerMacKeyRegistration.same("fd7a:115c:a1e0::1", "FD7A:115C:A1E0:0:0:0:0:1"))
        #expect(OwnerMacKeyRegistration.same("100.64.0.9", "100.64.0.9") && !OwnerMacKeyRegistration.same("100.64.0.9", "100.64.0.99"))
        #expect(!OwnerMacKeyRegistration.same("a name", "a name"))
    }

    /// One answer for one set of a name's addresses, in any order: the fleet's private network first.
    @Test func aNameWithTwoAddressesHasOneNumber() {
        #expect(OwnerMacKey.chosen(["192.0.2.28", "100.64.0.9", "fd7a:115c:a1e0::1"]) == "100.64.0.9")
        #expect(OwnerMacKey.chosen(["fd7a:115c:a1e0::1", "100.64.0.9", "192.0.2.28"]) == "100.64.0.9")
        #expect(OwnerMacKey.chosen(["192.0.2.28", "192.0.2.5"]) == "192.0.2.5")
        #expect(OwnerMacKey.chosen(["192.0.2.5", "192.0.2.28"]) == "192.0.2.5")
        #expect(OwnerMacKey.chosen(["100.64.0.10", "100.64.0.9"]) == "100.64.0.9")
        // The fleet's private network first, also where another address is the lower one.
        #expect(OwnerMacKey.chosen(["10.0.0.9", "100.64.0.9"]) == "100.64.0.9")
        #expect(OwnerMacKey.chosen(["100.64.0.9", "10.0.0.9"]) == "100.64.0.9")
        #expect(OwnerMacKey.chosen(["fd7a:115c:a1e0::2", "fd7a:115c:a1e0::1"]) == "fd7a:115c:a1e0::1")
        #expect(OwnerMacKey.chosen(["fd7a:115c:a1e0::2", "FD7A:115C:A1E0::1"]) == "fd7a:115c:a1e0::1")
        #expect(OwnerMacKey.chosen([]) == nil)
        #expect(OwnerMacKey.chosen(["not an address"]) == nil)
        // One address has one spelling, so its two ways of writing are one file and one place to call.
        #expect(OwnerMacKey.canonical("100.64.0.9") == "100.64.0.9")
        #expect(OwnerMacKey.canonical("FD7A:115C:A1E0:0:0:0:0:1") == "fd7a:115c:a1e0::1")
        #expect(OwnerMacKey.canonical("hub.example") == nil && OwnerMacKey.canonical("") == nil)
        let long = URL(string: "http://[fd7a:115c:a1e0:0:0:0:0:1]:8765")!, short = URL(string: "http://[fd7a:115c:a1e0::1]:8765")!
        #expect(OwnerMacKey.file(hub: long, home: home, lookup: Self.noLookup) == OwnerMacKey.file(hub: short, home: home, lookup: Self.noLookup))
        #expect(OwnerMacKey.file(hub: long, home: home, lookup: Self.noLookup)?.lastPathComponent == "fd7a-115c-a1e0--1_8765")
        #expect(throws: Never.self) { try OwnerMacKey.keep(Self.key, hub: short, home: home, lookup: Self.noLookup) }
        let signed = OwnerMacKey.authorized(URLRequest(url: long.appendingPathComponent("ui/state")), home: home, lookup: Self.noLookup)
        #expect(signed.url?.absoluteString == "http://[fd7a:115c:a1e0::1]:8765/ui/state")
        #expect(signed.value(forHTTPHeaderField: "Authorization") == "Bearer " + Self.key)
    }

    private func register(read: @escaping @Sendable (String) async throws -> String) async throws {
        try await OwnerMacKeyRegistration.run(hub: hub, home: home,
            post: { try await OwnerMacKeyRegistration.post(hub: $0, body: $1, session: KeyedHub.session) }, read: read)
    }

    @Test func theMacRegistersItsKeyWithTheValueOfTheFileOnTheHubsServer() async throws {
        let proof = state.proof
        try await register { program in
            #expect(program == OwnerMacKeyRegistration.program(path: "/home/fleet/.fleet/owner-key.proof"))
            return "a line of sudo\nfounderizer-proof:" + proof + "\n"
        }
        let key = try #require(OwnerMacKey.read(hub: hub, home: home))
        #expect(state.sha == OwnerMacKey.digest(key))
        #expect(state.seen.map(\.path) == ["/ui/owner/key", "/ui/owner/key"])
        #expect(state.seen.allSatisfy { $0.bearer == nil })
        #expect(state.seen[0].body.isEmpty)
        #expect(state.seen[1].body == ["sha256": OwnerMacKey.digest(key), "proof": proof])
        #expect(!state.seen.contains { $0.body.values.contains(key) })      // the key itself never goes
        // From now on the hub asks for the key, and this Mac has it. Nothing waits any more.
        #expect(status(try await read()) == 200)
        #expect(status(try await KeyedHub.session.data(for: URLRequest(url: hub.appendingPathComponent("ui/state")))) == 403)
        let folder = try #require(OwnerMacKey.file(hub: hub, home: home)).deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["\(host)_8765"])
    }

    /// The hub registered the key and its answer did not arrive. The key was written before the call, as the key that
    /// waits: this Mac's next read carries it, and the hub's answer makes it the key. No second registration is needed.
    @Test func anAnswerThatIsLostLosesNoKey() async throws {
        let proof = state.proof
        state.loses = 1
        await #expect(throws: OwnerMacKeyRegistration.Failure.noAnswer) {
            try await register { _ in "founderizer-proof:" + proof }
        }
        let waits = try #require(OwnerMacKey.waiting(hub: hub, home: home))
        #expect(state.sha == OwnerMacKey.digest(waits))                 // the hub holds it
        #expect(OwnerMacKey.read(hub: hub, home: home) == nil)
        #expect(status(try await read()) == 200)                        // the next read carries the key that waits
        #expect(OwnerMacKey.read(hub: hub, home: home) == waits)
        #expect(OwnerMacKey.waiting(hub: hub, home: home) == nil)
        #expect(OwnerMacKey.refused(hub: hub) == nil)
    }

    /// A key that waits and that the hub does not hold: a hub from before the key says that it expects none, and a
    /// hub with another key refuses it. Neither makes it this Mac's key.
    @Test func aKeyThatWaitsBecomesTheKeyOnlyWhenTheHubTakesIt() async throws {
        try OwnerMacKey.keepWaiting(Self.key, hub: hub, home: home)
        #expect(status(try await read()) == 200)                        // refused as not expected, then with no key
        #expect(state.seen.map(\.bearer) == [Self.key, nil])
        #expect(OwnerMacKey.read(hub: hub, home: home) == nil)
        state.sha = OwnerMacKey.digest(Self.other)
        OwnerMacKey.forget(hub: hub)
        #expect(status(try await read()) == 403)
        #expect(OwnerMacKey.read(hub: hub, home: home) == nil)
        #expect(OwnerMacKey.waiting(hub: hub, home: home) == Self.key)
        // A 404 never reached the owner's rule: it takes no refusal away and makes no key.
        state.sha = OwnerMacKey.digest(Self.key)
        let url = hub.appendingPathComponent("ui/state")
        var sent = URLRequest(url: url)
        sent.setValue("Bearer " + Self.key, forHTTPHeaderField: "Authorization")
        OwnerMacKey.took(sent, ours: true, answer: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                         Data(), home: home)
        #expect(OwnerMacKey.read(hub: hub, home: home) == nil)
        #expect(OwnerMacKey.refused(hub: hub) == .mismatch)
        #expect(status(try await read()) == 200)
        #expect(OwnerMacKey.read(hub: hub, home: home) == Self.key)
    }

    /// A hub that once expected no key holds this Mac's key now: the first refusal for want of a key ends the memory.
    @Test func aHubThatAsksForAKeyAgainGetsIt() async throws {
        try OwnerMacKey.keep(Self.key, hub: hub, home: home)
        #expect(status(try await read()) == 200)
        #expect(OwnerMacKey.notExpected(hub: hub, home: home))
        state.sha = OwnerMacKey.digest(Self.key)
        #expect(status(try await read()) == 403)                        // it went with no key, once
        #expect(!OwnerMacKey.notExpected(hub: hub, home: home))
        #expect(OwnerMacKey.refused(hub: hub) == nil)                   // and that refusal is not this key's
        #expect(status(try await read()) == 200)
        #expect(state.seen.last?.bearer == Self.key)
    }

    // ------------------------------------------------------------ a name and a number of one hub

    /// **One hub address has one key file, named by its number.** The claim's own line writes the file under the
    /// hub's number. An app that calls the same hub by its name on the private network looks the name up and reads
    /// that file, and writes a new key there. So there is no file of another spelling that could hold an older key.
    /// While the folder holds no file of that port nothing is looked up, and a name with no number has no key.
    @Test func oneHubAddressHasOneKeyFileNamedByItsNumber() throws {
        let asked = Asked()
        let lookup: (String) -> String? = { host in
            asked.add(host)
            return ["hub-1.tail1234.ts.net": "100.64.0.9", "other.tail1234.ts.net": "100.64.0.10"][host]
        }
        let byName = URL(string: "http://hub-1.tail1234.ts.net:8765")!, byNumber = URL(string: "http://100.64.0.9:8765")!
        let folder = home.appendingPathComponent(".founderizer/owner-keys", isDirectory: true)
        func files() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() }
        #expect(OwnerMacKey.read(hub: byName, home: home, lookup: lookup) == nil)
        #expect(asked.all.isEmpty)                                      // no file of that port: nothing to find
        try OwnerMacKey.keep(Self.key, hub: byNumber, home: home, lookup: Self.noLookup)
        #expect(OwnerMacKey.read(hub: byName, home: home, lookup: lookup) == Self.key)
        let request = URLRequest(url: byName.appendingPathComponent("ui/state"))
        #expect(OwnerMacKey.authorized(request, home: home, lookup: lookup).value(forHTTPHeaderField: "Authorization") == "Bearer " + Self.key)
        #expect(OwnerMacKey.read(hub: URL(string: "http://other.tail1234.ts.net:8765")!, home: home, lookup: lookup) == nil)
        #expect(OwnerMacKey.read(hub: URL(string: "http://hub-1.tail1234.ts.net:9000")!, home: home, lookup: lookup) == nil)
        #expect(OwnerMacKey.read(hub: URL(string: "http://100.64.0.10:8765")!, home: home, lookup: Self.noLookup) == nil)
        // A name that the system does not know finds nothing.
        #expect(OwnerMacKey.read(hub: URL(string: "http://unknown.tail1234.ts.net:8765")!, home: home, lookup: lookup) == nil)

        // A file with the name as it is written (no program writes one) is never the key: with a number the file of
        // the number is, and with no number there is no key. So a second claim, which writes the file of the number,
        // reaches an app that calls the hub by its name.
        try Data((Self.other + "\n").utf8).write(to: folder.appendingPathComponent("hub-1.tail1234.ts.net_8765"))
        #expect(OwnerMacKey.read(hub: byName, home: home, lookup: lookup) == Self.key)
        #expect(OwnerMacKey.read(hub: byName, home: home, lookup: { _ in nil }) == nil)
        #expect(OwnerMacKey.authorized(request, home: home, lookup: { _ in nil }).value(forHTTPHeaderField: "Authorization") == nil)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("hub-1.tail1234.ts.net_8765"))

        // A name with no number now has no place: nothing is kept for it, as a key or as a key that waits.
        #expect(throws: OwnerMacKey.NotKept.self) { try OwnerMacKey.keep(Self.other, hub: byName, home: home, lookup: { _ in nil }) }
        #expect(throws: OwnerMacKey.NotKept.self) { try OwnerMacKey.keepWaiting(Self.other, hub: byName, home: home, lookup: { _ in nil }) }
        OwnerMacKey.promote(Self.other, hub: byName, home: home, lookup: { _ in nil })
        #expect(try files() == ["100.64.0.9_8765"])
        #expect(OwnerMacKey.read(hub: byNumber, home: home, lookup: Self.noLookup) == Self.key)

        // A new key of the app that calls by name goes to the file of the number.
        let third = "k" + String(repeating: "d", count: 42)
        try OwnerMacKey.keepWaiting(third, hub: byName, home: home, lookup: lookup)
        #expect(try files() == ["100.64.0.9_8765", "100.64.0.9_8765.pending"])
        #expect(OwnerMacKey.waiting(hub: byNumber, home: home, lookup: Self.noLookup) == third)
        OwnerMacKey.promote(third, hub: byName, home: home, lookup: lookup)
        #expect(try files() == ["100.64.0.9_8765"])
        #expect(OwnerMacKey.read(hub: byNumber, home: home, lookup: Self.noLookup) == third)
        try OwnerMacKey.keep(Self.key, hub: byName, home: home, lookup: lookup)
        #expect(try files() == ["100.64.0.9_8765"])
        #expect(OwnerMacKey.read(hub: byNumber, home: home, lookup: Self.noLookup) == Self.key)
    }

    /// **The key goes to the number that named its file, and never to the name again.** A connection looks a name up
    /// by itself, and that second answer can be another host than the first: a name that somebody else controls
    /// could answer the hub's number to the one and its own host to the other. So one lookup decides the key and
    /// where the request goes.
    @Test func aRequestWithTheKeyGoesToTheHubsNumberAndNeverToItsName() async throws {
        let name = "hub-\(UUID().uuidString.lowercased().prefix(8)).tail1234.ts.net", number = host
        let byName = URL(string: "http://\(name):8765")!, home = home
        try OwnerMacKey.keep(Self.key, hub: hub, home: home, lookup: Self.noLookup)
        let request = URLRequest(url: URL(string: "http://\(name):8765/ui/state?db=g1")!)
        // The first answer is the hub's number, and each later one is another host: one lookup, and no key for the other.
        let asked = Asked()
        let turning: @Sendable (String) -> String? = { host in
            asked.add(host)
            return asked.all.count == 1 ? number : "100.64.0.99"
        }
        let signed = OwnerMacKey.authorized(request, home: home, lookup: turning)
        #expect(asked.all == [name])
        #expect(signed.url?.absoluteString == "http://\(number):8765/ui/state?db=g1")
        #expect(signed.value(forHTTPHeaderField: "Authorization") == "Bearer " + Self.key)
        let second = OwnerMacKey.authorized(request, home: home, lookup: turning)       // the name is another host now
        #expect(second.url == request.url)
        #expect(second.value(forHTTPHeaderField: "Authorization") == nil)
        // A number of the other kind, in the brackets that an address needs.
        let six = URL(string: "http://[fd7a:115c:a1e0::1]:8765")!
        try OwnerMacKey.keep(Self.other, hub: six, home: home, lookup: Self.noLookup)
        let toSix = OwnerMacKey.authorized(request, home: home, lookup: { _ in "FD7A:115C:A1E0::1" })
        #expect(toSix.url?.absoluteString == "http://[fd7a:115c:a1e0::1]:8765/ui/state?db=g1")
        #expect(toSix.value(forHTTPHeaderField: "Authorization") == "Bearer " + Self.other)

        // The whole call: the hub at the number gets the request with the key, and the name gets nothing. What the
        // hub answered is kept under the name that the app calls it by.
        state.sha = OwnerMacKey.digest(Self.key)
        let lookup: @Sendable (String) -> String? = { _ in number }
        #expect(status(try await KeyedHub.session.hubData(for: request, home: home, lookup: lookup)) == 200)
        #expect(state.seen.map(\.bearer) == [Self.key])
        #expect(KeyedHub.hub(name).seen.isEmpty)
        state.sha = OwnerMacKey.digest(Self.other)
        #expect(status(try await KeyedHub.session.hubData(for: request, home: home, lookup: lookup)) == 403)
        #expect(OwnerMacKey.refused(hub: byName) == .mismatch)
        // A hub from before the key: the call with the key went to the number, and the same call with no key goes
        // as its address is written.
        state.sha = nil
        #expect(status(try await KeyedHub.session.hubData(for: request, home: home, lookup: lookup)) == 200)
        #expect(state.seen.map(\.bearer) == [Self.key, Self.key, Self.key])
        #expect(KeyedHub.hub(name).seen.map(\.bearer) == [nil])
        OwnerMacKey.forget(hub: byName)
    }

    /// An answer of a route that asks nobody for a key says nothing of this Mac's key: it makes no key of the one
    /// that waits, and it takes no refusal away.
    @Test func anAnswerOfARouteThatAsksForNoKeySaysNothingOfTheKey() throws {
        try OwnerMacKey.keepWaiting(Self.key, hub: hub, home: home, lookup: Self.noLookup)
        func took(_ path: String, _ status: Int, _ body: String = "{}") {
            let url = hub.appendingPathComponent(path)
            var sent = URLRequest(url: url)
            sent.setValue("Bearer " + Self.key, forHTTPHeaderField: "Authorization")
            OwnerMacKey.took(sent, ours: true, answer: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                             Data(body.utf8), home: home, lookup: Self.noLookup)
        }
        took("ui/state", 403, #"{"auth": "owner_key_mismatch"}"#)
        #expect(OwnerMacKey.refused(hub: hub) == .mismatch)
        for path in ["health", "outbox", "join", "ui/owner/key", "ui/owner/enroll"] {
            took(path, 200)
            #expect(OwnerMacKey.read(hub: hub, home: home, lookup: Self.noLookup) == nil, "\(path)")
            #expect(OwnerMacKey.waiting(hub: hub, home: home, lookup: Self.noLookup) == Self.key, "\(path)")
            #expect(OwnerMacKey.refused(hub: hub) == .mismatch, "\(path)")
        }
        took("ui/state", 200)
        #expect(OwnerMacKey.read(hub: hub, home: home, lookup: Self.noLookup) == Self.key)
        #expect(OwnerMacKey.refused(hub: hub) == nil)
    }

    /// **One registration has one place.** A hub that is called by a name is looked up once, before anything is
    /// sent: the key that waits and the key that is kept go to the file of that one number, whatever a later lookup
    /// says. A name that has no number now registers nothing, and nothing is sent.
    @Test func aRegistrationFindsItsPlaceOnceAndANameWithNoNumberRegistersNothing() async throws {
        let name = "hub-\(UUID().uuidString.lowercased().prefix(8)).tail1234.ts.net", number = host
        let hub = URL(string: "http://\(name):8765")!, state = state, home = home, proof = state.proof
        let post: @Sendable (URL, [String: String]) async throws -> (status: Int, data: Data) = {
            try await OwnerMacKeyRegistration.post(hub: $0, body: $1, session: KeyedHub.session)
        }
        // What the program prints on the hub's own server, which has the number among its addresses.
        let printed = "founderizer-proof:" + proof + "\nfounderizer-addresses:1: lo    inet 127.0.0.1/8 scope host lo 3: tailscale0    inet \(number)/32 scope global\n"
        await #expect(throws: OwnerMacKeyRegistration.Failure.notKept) {
            try await OwnerMacKeyRegistration.run(hub: hub, home: home, lookup: { _ in nil }, post: post, read: { _ in printed })
        }
        #expect(state.seen.isEmpty && KeyedHub.hub(name).seen.isEmpty)      // nothing was sent
        #expect(state.sha == nil)
        // The lookup answers once and then no more: the registration keeps its one answer, and its own calls go to
        // that number, as each later call with the key does.
        let asked = Asked()
        try await OwnerMacKeyRegistration.run(hub: hub, home: home, lookup: { host in
            asked.add(host)
            return asked.all.count == 1 ? number : nil
        }, post: post, read: { _ in printed })
        #expect(asked.all == [name])
        #expect(state.seen.map(\.path) == ["/ui/owner/key", "/ui/owner/key"])
        #expect(KeyedHub.hub(name).seen.isEmpty)
        let key = try #require(OwnerMacKey.read(hub: self.hub, home: home, lookup: Self.noLookup))
        #expect(state.sha == OwnerMacKey.digest(key))
        let folder = home.appendingPathComponent(".founderizer/owner-keys", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["\(number)_8765"])
    }

    /// **Whoever answers a name's lookup chooses its number.** The value is read over SSH from the hub's own server,
    /// whose host key this Mac knows. So the number of a name must be an address of that server, or the value goes
    /// to nobody: with the number taken on trust, the machine that answered the lookup would get the value, register
    /// a key of its own with it, and get this Mac's key on each call after.
    @Test func theNumberOfANameMustBeAnAddressOfTheServerThatTheValueWasReadFrom() async throws {
        let name = "hub-\(UUID().uuidString.lowercased().prefix(8)).tail1234.ts.net", other = host
        let hub = URL(string: "http://\(name):8765")!, state = state, home = home, proof = state.proof
        let post: @Sendable (URL, [String: String]) async throws -> (status: Int, data: Data) = {
            try await OwnerMacKeyRegistration.post(hub: $0, body: $1, session: KeyedHub.session)
        }
        // The lookup's number is the address of another machine: it answers the first call with the real path.
        for printed in ["founderizer-proof:" + proof + "\nfounderizer-addresses:2: enp0s1    inet 100.64.0.9/32 scope global\n",
                        "founderizer-proof:" + proof + "\nfounderizer-addresses:\n",
                        "founderizer-proof:" + proof + "\n",
                        "founderizer-addresses:inet \(other)\nfounderizer-proof:" + proof + "\nfounderizer-addresses:inet 100.64.0.9\n"] {
            await #expect(throws: OwnerMacKeyRegistration.Failure.notThisServer) {
                try await OwnerMacKeyRegistration.run(hub: hub, home: home, lookup: { _ in other }, post: post, read: { _ in printed })
            }
        }
        #expect(state.seen.count == 4)
        #expect(state.seen.allSatisfy { $0.body.isEmpty && $0.bearer == nil })      // the value went to nobody
        #expect(state.sha == nil)
        let folder = home.appendingPathComponent(".founderizer/owner-keys", isDirectory: true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty)   // and no key was made
        // **A number that every machine has is no proof of the server.** The hub's server has a loopback address, a
        // link-local one and the address of a bridge, and so does this Mac, where each is another machine's door (a
        // container's published port). Only an address of the fleet's private network that the server has passes.
        let everywhere = ["127.0.0.1", "::1", "172.17.0.1", "192.168.64.1", "169.254.1.1", "fe80::1", "10.0.0.1", "192.0.2.28"]
        let printed = "founderizer-proof:" + proof + "\nfounderizer-addresses:"
            + everywhere.map { ($0.contains(":") ? "inet6 " : "inet ") + $0 }.joined(separator: " ") + "\n"
        #expect(OwnerMacKeyRegistration.addresses(printed) == everywhere)
        for number in everywhere {
            #expect(!OwnerMacKey.isOfFleetNetwork(number), "\(number)")
            await #expect(throws: OwnerMacKeyRegistration.Failure.notThisServer) {
                try await OwnerMacKeyRegistration.run(hub: hub, home: home, lookup: { _ in number }, post: post, read: { _ in printed })
            }
            #expect(KeyedHub.hub(number).seen.allSatisfy { $0.body.isEmpty }, "\(number)")       // the value went to nobody
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty)
        // The two ends of the range, written from their parts (no machine's address stands in this file).
        func quad(_ parts: Int...) -> String { parts.map(String.init).joined(separator: ".") }
        for number in ["100.64.0.9", "100.70.1.9", quad(100, 64, 0, 0), quad(100, 127, 255, 255), "fd7a:115c:a1e0::1", "FD7A:115C:A1E0:ab12::9"] {
            #expect(OwnerMacKey.isOfFleetNetwork(number), "\(number)")
        }
        for number in [quad(100, 63, 255, 255), quad(100, 128, 0, 0), "fd7a:115c:a1e1::1", "fd00::1", "hub.example", ""] {
            #expect(!OwnerMacKey.isOfFleetNetwork(number), "\(number)")
        }
        // A hub that is written as a number is the owner's own word for where the hub is: no such check.
        try await OwnerMacKeyRegistration.run(hub: self.hub, home: home, lookup: Self.noLookup, post: post,
                                              read: { _ in "founderizer-proof:" + proof + "\nfounderizer-addresses:inet 100.64.0.9\n" })
        #expect(OwnerMacKey.read(hub: self.hub, home: home, lookup: Self.noLookup) != nil)
    }

    /// **A key that waits and that the hub refuses too goes no more.** Two copies of the app register after a
    /// refusal; the hub takes the first one's key, which that copy puts in the file, and the second one's key still
    /// waits. The second copy sends the key that waits once, the hub refuses it, and then the key of the file goes,
    /// which is the right one. Without this, that copy sends the refused key on every call.
    @Test func aKeyThatWaitsAndIsRefusedGivesWayToTheKeyOfTheFile() async throws {
        let before = "k" + String(repeating: "a", count: 42)
        let file = try #require(OwnerMacKey.file(hub: hub, home: home, lookup: Self.noLookup))
        try OwnerMacKey.keep(before, hub: hub, home: home, lookup: Self.noLookup)
        state.sha = OwnerMacKey.digest(Self.key)
        #expect(status(try await read()) == 403)                        // the key from before: refused
        #expect(OwnerMacKey.refused(hub: hub) == .mismatch)
        // The other copy's registration went through and it wrote its key; this copy's own key still waits.
        try Data((Self.key + "\n").utf8).write(to: file)
        try Data((Self.other + "\n").utf8).write(to: file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".pending"))
        #expect(status(try await read()) == 403)                        // the key that waits, once
        #expect(status(try await read()) == 200)                        // then the key of the file
        #expect(status(try await read()) == 200)
        #expect(state.seen.map(\.bearer) == [before, Self.other, Self.key, Self.key])
        #expect(OwnerMacKey.refused(hub: hub) == nil)
        #expect(OwnerMacKey.waiting(hub: hub, home: home, lookup: Self.noLookup) == Self.other)    // until the next registration
        // Another key that waits later is a new one: it is tried when the hub refuses the key again.
        state.sha = OwnerMacKey.digest(before)
        #expect(status(try await read()) == 403)
        #expect(status(try await read()) == 403)                        // the key that waits was refused before: not it
        #expect(state.seen.suffix(2).map(\.bearer) == [Self.key, Self.key])
        try OwnerMacKey.keepWaiting(before, hub: hub, home: home, lookup: Self.noLookup)
        #expect(status(try await read()) == 200)
        #expect(OwnerMacKey.read(hub: hub, home: home, lookup: Self.noLookup) == before)
    }

    /// **The first requests of a run start together.** One caller asks the resolver for the hub's name, and each
    /// other caller waits for that one answer: with nil at once, it would send its request with no key, and the hub
    /// would refuse it. A name that the resolver does not know gives nil to all of them, after one question.
    @Test func callersWaitForTheOneLookupOfANameThatIsOnItsWay() {
        for (addresses, expected) in [(["192.0.2.28", "100.64.0.9"], "100.64.0.9" as String?), ([], nil)] {
            let name = "hub-\(UUID().uuidString.lowercased().prefix(8)).tail1234.ts.net", asked = Asked(), got = Asked()
            DispatchQueue.concurrentPerform(iterations: 24) { _ in
                let found = OwnerMacKey.lookedUp(name, ask: { host in
                    asked.add(host)
                    Thread.sleep(forTimeInterval: 0.3)
                    return addresses
                })
                got.add(found ?? "nil")
            }
            #expect(asked.all == [name])
            #expect(got.all == Array(repeating: expected ?? "nil", count: 24))
            // And then the answer is kept: no second question.
            #expect(OwnerMacKey.lookedUp(name, ask: { _ in Issue.record("a second lookup"); return [] }) == expected)
        }
        // A caller does not wait for ever for another caller's question.
        let slow = "hub-\(UUID().uuidString.lowercased().prefix(8)).tail1234.ts.net", done = Asked()
        let first = Thread { _ = OwnerMacKey.lookedUp(slow, ask: { _ in Thread.sleep(forTimeInterval: 1.2); return ["100.64.0.9"] }) }
        first.start()
        Thread.sleep(forTimeInterval: 0.1)
        let start = Date()
        #expect(OwnerMacKey.lookedUp(slow, ask: { _ in done.add("asked"); return [] }, wait: 0.2) == nil)
        #expect(Date().timeIntervalSince(start) < 1.0 && done.all.isEmpty)
        Thread.sleep(forTimeInterval: 1.3)
        #expect(OwnerMacKey.lookedUp(slow, ask: { _ in [] }) == "100.64.0.9")
    }

    /// **One lookup that fails does not take a name's number away.** The resolver of this process can fail for a
    /// moment while the connection still finds the hub. The number of the last answer stands in, ten minutes at
    /// most, and the resolver is asked again every ten seconds.
    @Test func aLookupThatFailsKeepsTheNumberFromBeforeForTenMinutes() {
        let name = "hub-\(UUID().uuidString.lowercased().prefix(8)).tail1234.ts.net", asked = Asked()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func looked(after seconds: TimeInterval, _ answer: [String]) -> String? {
            OwnerMacKey.lookedUp(name, ask: { host in asked.add(host); return answer }, clock: { start.addingTimeInterval(seconds) })
        }
        #expect(looked(after: 0, ["100.64.0.9"]) == "100.64.0.9")
        #expect(looked(after: 59, []) == "100.64.0.9" && asked.all.count == 1)      // kept for a minute: no question
        #expect(looked(after: 61, []) == "100.64.0.9" && asked.all.count == 2)      // the lookup fails: the number stays
        #expect(looked(after: 65, []) == "100.64.0.9" && asked.all.count == 2)      // and nobody asks for ten seconds
        #expect(looked(after: 72, []) == "100.64.0.9" && asked.all.count == 3)
        #expect(looked(after: 83, ["100.64.0.10"]) == "100.64.0.10" && asked.all.count == 4)   // a new answer is the number
        #expect(looked(after: 83 + 61, []) == "100.64.0.10")
        // Ten minutes after its last answer, a name that the resolver still does not know has no number.
        #expect(looked(after: 83 + OwnerMacKey.lookupKept - 1, []) == "100.64.0.10")
        #expect(looked(after: 83 + OwnerMacKey.lookupKept + 12, []) == nil)
        #expect(looked(after: 83 + OwnerMacKey.lookupKept + 30, ["100.64.0.9"]) == "100.64.0.9")
        // A name that never had a number has none.
        let never = "hub-\(UUID().uuidString.lowercased().prefix(8)).tail1234.ts.net"
        #expect(OwnerMacKey.lookedUp(never, ask: { _ in [] }, clock: { start }) == nil)
    }

    /// **A key that waits and that the hub refused goes once more after half a minute**, while the hub still refuses
    /// the key: the hub can have taken the registration after it answered the first call with that key (an answer
    /// that was lost, and a hub that was slow). The hub's yes then makes it the key.
    @Test func aRefusedKeyThatWaitsIsTriedAgainAfterHalfAMinute() async throws {
        let before = "k" + String(repeating: "a", count: 42)
        try OwnerMacKey.keep(before, hub: hub, home: home, lookup: Self.noLookup)
        try OwnerMacKey.keepWaiting(Self.key, hub: hub, home: home, lookup: Self.noLookup)
        state.sha = OwnerMacKey.digest(Self.other)                      // the hub holds neither yet
        #expect(status(try await read()) == 403)                        // the key from before
        #expect(status(try await read()) == 403)                        // the key that waits
        #expect(status(try await read()) == 403)                        // the key from before again
        #expect(state.seen.map(\.bearer) == [before, Self.key, before])
        let request = URLRequest(url: hub.appendingPathComponent("ui/state"))
        func carried(after seconds: TimeInterval) -> String? {
            OwnerMacKey.signing(request, home: home, lookup: Self.noLookup, now: Date().addingTimeInterval(seconds)).key
        }
        #expect(carried(after: 1) == before)
        #expect(carried(after: OwnerMacKey.waitsRetry - 2) == before)
        #expect(carried(after: OwnerMacKey.waitsRetry + 1) == Self.key)         // once more
        // The hub took the registration in the meantime: its yes to the key that waits makes it the key.
        state.sha = OwnerMacKey.digest(Self.key)
        var sent = request
        sent.setValue("Bearer " + Self.key, forHTTPHeaderField: "Authorization")
        OwnerMacKey.took(sent, ours: true, answer: HTTPURLResponse(url: sent.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                         Data("{}".utf8), home: home, lookup: Self.noLookup)
        #expect(OwnerMacKey.read(hub: hub, home: home, lookup: Self.noLookup) == Self.key)
        #expect(OwnerMacKey.waiting(hub: hub, home: home, lookup: Self.noLookup) == nil)
        #expect(OwnerMacKey.refused(hub: hub) == nil)
        #expect(status(try await read()) == 200)
    }

    /// A read that takes its answer as a stream and checks the answer's address against its own request's (the app's
    /// reads of a file, of the team, of the servers): for a hub that is called by a name the request goes to the
    /// number, and the answer still has the address that the read asked.
    @Test func aStreamedReadOfAHubByItsNameGetsItsAnswerUnderThatName() async throws {
        let name = "hub-\(UUID().uuidString.lowercased().prefix(8)).tail1234.ts.net", number = host
        try OwnerMacKey.keep(Self.key, hub: hub, home: home, lookup: Self.noLookup)
        state.sha = OwnerMacKey.digest(Self.key)
        let request = URLRequest(url: URL(string: "http://\(name):8765/ui/health?db=g1")!)
        let (bytes, response) = try await KeyedHub.session.hubBytes(for: request, home: home, lookup: { _ in number })
        var body = Data()
        for try await byte in bytes { body.append(byte) }
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(response.url == request.url)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(String(decoding: body, as: UTF8.self) == "{}")
        #expect(state.seen.map(\.bearer) == [Self.key] && KeyedHub.hub(name).seen.isEmpty)
        // The same through `hubData`, and a hub that is written as a number has its answer as it came.
        let (_, answer) = try await KeyedHub.session.hubData(for: request, home: home, lookup: { _ in number })
        #expect(answer.url == request.url)
        let direct = URLRequest(url: hub.appendingPathComponent("ui/health"))
        #expect(try await KeyedHub.session.hubBytes(for: direct, home: home, lookup: Self.noLookup).1.url == direct.url)
        // With no key for the name's number, the request goes to the name as it is written.
        let (_, plain) = try await KeyedHub.session.hubBytes(for: request, home: home, lookup: { _ in "100.64.0.99" })
        #expect(plain.url == request.url && KeyedHub.hub(name).seen.count == 1)
    }

    /// **Two programs of this Mac register at one time.** The second one's key waits in the file by the time the
    /// hub's yes to the first one arrives: the first one's key is the key, because the hub holds it, and the other
    /// one still waits for its own answer.
    @Test func theKeyThatTheHubTookIsKeptWhateverWaitsBesideIt() async throws {
        let proof = state.proof, hub = hub, home = home
        try await OwnerMacKeyRegistration.run(hub: hub, home: home, lookup: Self.noLookup, post: { target, body in
            let answer = try await OwnerMacKeyRegistration.post(hub: target, body: body, session: KeyedHub.session)
            if body["proof"] != nil { try OwnerMacKey.keepWaiting(Self.other, hub: hub, home: home, lookup: Self.noLookup) }
            return answer
        }, read: { _ in "founderizer-proof:" + proof })
        let key = try #require(OwnerMacKey.read(hub: hub, home: home, lookup: Self.noLookup))
        #expect(key != Self.other)
        #expect(state.sha == OwnerMacKey.digest(key))
        #expect(OwnerMacKey.waiting(hub: hub, home: home, lookup: Self.noLookup) == Self.other)
        // A hub that refuses the first one's value while the other one's key waits: that key stays too.
        state.proof = "q" + String(repeating: "B", count: 42)
        await #expect(throws: OwnerMacKeyRegistration.Failure.refused) {
            try await OwnerMacKeyRegistration.run(hub: hub, home: home, lookup: Self.noLookup, post: { target, body in
                let answer = try await OwnerMacKeyRegistration.post(hub: target, body: body, session: KeyedHub.session)
                if body["proof"] != nil { try OwnerMacKey.keepWaiting(Self.other, hub: hub, home: home, lookup: Self.noLookup) }
                return answer
            }, read: { _ in "founderizer-proof:" + proof })
        }
        #expect(OwnerMacKey.waiting(hub: hub, home: home, lookup: Self.noLookup) == Self.other)
        #expect(OwnerMacKey.read(hub: hub, home: home, lookup: Self.noLookup) == key)
    }

    /// A call that the hub took carried a key that waits no more: another program's key waits there by then. The
    /// answer makes no key of either one.
    @Test func anAnswerToAKeyThatWaitsNoMoreMakesNoKey() throws {
        let url = hub.appendingPathComponent("ui/state")
        var sent = URLRequest(url: url)
        sent.setValue("Bearer " + Self.key, forHTTPHeaderField: "Authorization")
        try OwnerMacKey.keepWaiting(Self.other, hub: hub, home: home, lookup: Self.noLookup)
        let passed = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        OwnerMacKey.took(sent, ours: true, answer: passed, Data("{}".utf8), home: home, lookup: Self.noLookup)
        #expect(OwnerMacKey.read(hub: hub, home: home, lookup: Self.noLookup) == nil)
        #expect(OwnerMacKey.waiting(hub: hub, home: home, lookup: Self.noLookup) == Self.other)
        // The key that waits now, carried by a request that was not signed here (a phone's own key): no key either.
        var phone = URLRequest(url: url)
        phone.setValue("Bearer " + Self.other, forHTTPHeaderField: "Authorization")
        OwnerMacKey.took(phone, ours: false, answer: passed, Data("{}".utf8), home: home, lookup: Self.noLookup)
        #expect(OwnerMacKey.read(hub: hub, home: home, lookup: Self.noLookup) == nil)
    }

    @Test func theAppAsksOffTheMainActorWhatThisMacHoldsForItsHub() async throws {
        #expect(await OwnerMacKey.holding(hub: hub, home: home, lookup: Self.noLookup) == .none)
        try OwnerMacKey.keepWaiting(Self.key, hub: hub, home: home, lookup: Self.noLookup)
        #expect(await OwnerMacKey.holding(hub: hub, home: home, lookup: Self.noLookup) == .none)       // a key that waits is no key
        try OwnerMacKey.keep(Self.key, hub: hub, home: home, lookup: Self.noLookup)
        #expect(await OwnerMacKey.holding(hub: hub, home: home, lookup: Self.noLookup) == .key)
        // The same hub by a name: its number's file, and nothing is known while the name has no number.
        let host = host, byName = URL(string: "http://hub-1.tail1234.ts.net:8765")!
        #expect(await OwnerMacKey.holding(hub: byName, home: home, lookup: { _ in host }) == .key)
        #expect(await OwnerMacKey.holding(hub: byName, home: home, lookup: { _ in "100.64.0.99" }) == .none)
        #expect(await OwnerMacKey.holding(hub: byName, home: home, lookup: { _ in nil }) == .unknown)
        #expect(status(try await read()) == 200)                        // a hub from before the key: it expects none
        #expect(await OwnerMacKey.holding(hub: hub, home: home, lookup: Self.noLookup) == .none)
    }

    // ------------------------------------------------------------ when the app registers

    @Test func theAppRegistersWhenTheHubTakesKeysAndThisMacHasNone() {
        func step(held: Bool = false, known: Bool = true, refused: Bool = false, takesKeys: Bool = true, fresh: Bool = true,
                  remembered: Bool = false, tries: VaultTries? = nil, registered: Double? = nil, now: Double = 10_000) -> OwnerKeyPlan.Step {
            OwnerKeyPlan.step(held: held, known: known, refused: refused, takesKeys: takesKeys, fresh: fresh,
                              remembered: remembered, tries: tries, registered: registered, now: now)
        }
        #expect(step() == .register)
        // The hub's name has no number now: nothing says whether this Mac has a key, and a new one would have no
        // place. Nothing is registered, whatever the hub answers.
        #expect(step(known: false) == .nothing)
        #expect(step(known: false, refused: true) == .nothing)
        #expect(step(takesKeys: false) == .nothing)                     // a hub from before the key
        #expect(step(fresh: false) == .nothing)                         // a hub that does not answer says nothing
        // The hub refuses for want of the key: this Mac reads nothing, and that refusal is the reason to register.
        #expect(step(refused: true, takesKeys: false, fresh: false) == .register)
        #expect(step(held: true, refused: true, fresh: false) == .register)
        // In order: once in a run, keep the connection to the hub's server.
        #expect(step(held: true) == .remember)
        #expect(step(held: true, remembered: true) == .nothing)
        #expect(step(held: true, fresh: false) == .nothing)
        // A try that failed comes again after ten minutes, six times at most.
        let failed = VaultTries.failed(after: nil, at: 10_000, reason: "x")
        #expect(step(tries: failed, now: 10_000 + VaultTries.wait - 1) == .nothing)
        #expect(step(tries: failed, now: 10_000 + VaultTries.wait) == .register)
        #expect(step(tries: VaultTries(failures: VaultTries.most, last: 0, reason: "x"), now: 1_000_000) == .nothing)
        // A registration that went through is not made again for ten minutes, whatever the hub answers.
        #expect(step(refused: true, registered: 10_000, now: 10_000 + VaultTries.wait - 1) == .nothing)
        #expect(step(refused: true, registered: 10_000, now: 10_000 + VaultTries.wait) == .register)
    }

    @Test func theBlockShowsAtOnceOnlyWhenNoConnectionIsOnRecord() {
        let target = OwnerKeyPlan.Reach.target(InstallTarget(host: "100.64.0.9"))
        #expect(OwnerKeyPlan.cannot(reach: .none, failures: 1))         // the record is known: another try changes nothing
        #expect(!OwnerKeyPlan.cannot(reach: .unknown, failures: 1))     // one read that failed puts nothing on a page
        #expect(!OwnerKeyPlan.cannot(reach: target, failures: 1))       // and neither does one lost connection
        #expect(OwnerKeyPlan.cannot(reach: .unknown, failures: 2))
        #expect(OwnerKeyPlan.cannot(reach: target, failures: 2))
    }

    /// 15 November 2026: a hub from before the key, installed by hand on a server that runs no agent. The list of
    /// machines does not name that server, so this Mac found no connection and registered no key, although the hub
    /// had the connection on record for its own server (`GET /ui/vault`).
    @Test func theHubsOwnRecordGivesTheConnectionToAServerWithNoAgent() throws {
        func record(_ server: String = "hub-1", listed: MachineReach? = nil, listRead: Bool = true, own: VaultHub?,
                    ownRead: Bool = true) -> OwnerKeyPlan.Record {
            OwnerKeyPlan.record(server: server, listed: listed, listRead: listRead, own: own, ownRead: ownRead)
        }
        let hubs = try Self.own(#""ssh": {"user": "fleet", "port": 2222}"#)
        let reach = MachineReach(address: "100.64.0.2", user: "fleet", port: 2222)
        #expect(record(own: hubs) == .reach(reach))                     // the list does not name the server
        #expect(record(listRead: false, own: hubs) == .reach(reach))    // and when the list did not answer
        // The record of another machine is not this server's.
        #expect(record("hub-2", own: hubs) == .none)
        // A record that is not a whole connection is none: no user, no port, no address, a user that is no user name.
        // The hub's own page names the server, so this is known also when the list did not answer.
        for part in [#""ssh": null"#, #""ssh": {"user": null, "port": 22}"#, #""ssh": {"user": "root", "port": null}"#,
                     #""ssh": {"user": "root", "port": 0}"#, #""ssh": {"user": "root -oProxyCommand=x", "port": 22}"#] {
            #expect(record(own: try Self.own(part)) == .none)
            #expect(record(listRead: false, own: try Self.own(part)) == .none)
        }
        #expect(record(own: try Self.own(#""ssh": {"user": "root", "port": 22}"#, address: "null")) == .none)
        #expect(record(listRead: false, own: try Self.own(#""ssh": {"user": "root", "port": 22}"#, address: "null")) == .none)
        // The list comes first. When it names the server, its entry is the fleet's record, whole or not: the hub's
        // own page has the same entry, so it is not asked, and it changes nothing when it says something else.
        let listed = MachineReach(address: "100.64.0.9", user: "root", port: 22)
        #expect(record(listed: listed, own: hubs) == .reach(listed))
        #expect(record(listed: listed, own: nil, ownRead: false) == .reach(listed))
        for part in [MachineReach(address: "100.64.0.9"), MachineReach(address: "100.64.0.9", user: "root"),
                     MachineReach(address: "100.64.0.9", port: 22), MachineReach(address: nil, user: "root", port: 22)] {
            #expect(record(listed: part, own: nil, ownRead: false) == .none)
            #expect(record(listed: part, own: hubs) == .none)
        }
        // A page that did not answer says nothing, and two pages that answered with no connection say "none".
        #expect(record(own: nil) == .none)
        #expect(record(listRead: false, own: nil) == .unknown)
        #expect(record(own: nil, ownRead: false) == .unknown)
        #expect(record(listRead: false, own: nil, ownRead: false) == .unknown)
        #expect(record("hub-2", listRead: false, own: hubs) == .unknown)
    }

    /// The hub's record of its own server, as `GET /ui/vault` gives it.
    private static func own(_ ssh: String, machine: String = "hub-1", address: String = #""100.64.0.2""#) throws -> VaultHub {
        try JSONDecoder().decode(VaultHub.self, from: Data(#"{"machine": "\#(machine)", "address": \#(address), \#(ssh)}"#.utf8))
    }

    /// The list of machines with one server that an agent runs on, as `GET /ui/machines` gives it.
    private static func machines(_ name: String, ssh: String) throws -> [MachineStatus] {
        let json = #"""
        {"db":"db","machines":[{"agent":"manager","machine":"\#(name)","role":"manager","address":"100.64.0.9",
          "access":{"ssh":\#(ssh),"screen_sharing":null},"update":{},"runtime":{},"security":{},"os":{"name":"Ubuntu"}}]}
        """#
        return try JSONDecoder().decode(MachineList.self, from: Data(json.utf8)).machines
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private struct NoAnswer: Error {}

    /// The two reads in their order: the hub's own page is asked only when the list does not name the server, and a
    /// read that failed is not an answer.
    @Test func theHubsOwnPageIsAskedOnlyWhenTheListDoesNotNameTheServer() async throws {
        let hubs = try Self.own(#""ssh": {"user": "fleet", "port": 2222}"#)
        let reach = MachineReach(address: "100.64.0.2", user: "fleet", port: 2222)
        let other = try Self.machines("worker-1", ssh: #"{"user":"root","port":22,"available":true}"#)
        let whole = try Self.machines("hub-1", ssh: #"{"user":"root","port":22,"available":true}"#)
        let notWhole = try Self.machines("hub-1", ssh: "null")
        func record(_ list: [MachineStatus]?, own: Result<VaultHub?, NoAnswer>) async -> (OwnerKeyPlan.Record, Int) {
            let asked = Calls()
            let found = await OwnerKeyPlan.record(server: "hub-1", machines: { list },
                                                  own: { asked.add(); return try own.get() })
            return (found, asked.value)
        }
        // The list names the server: its entry is the record, and the second page is not read.
        #expect(await record(whole, own: .success(hubs)) == (.reach(MachineReach(address: "100.64.0.9", user: "root", port: 22)), 0))
        #expect(await record(notWhole, own: .success(hubs)) == (.none, 0))
        // The list answered and does not name the server: the hub's own page decides.
        #expect(await record(other, own: .success(hubs)) == (.reach(reach), 1))
        #expect(await record(other, own: .success(nil)) == (.none, 1))
        #expect(await record(other, own: .failure(NoAnswer())) == (.unknown, 1))
        #expect(await record([], own: .success(hubs)) == (.reach(reach), 1))
        // The list did not answer: the hub's own page still gives the record when it names the server, whole or not.
        // A hub that names no server of its own, or another one, leaves nothing known.
        #expect(await record(nil, own: .success(hubs)) == (.reach(reach), 1))
        #expect(await record(nil, own: .success(try Self.own(#""ssh": null"#))) == (.none, 1))
        #expect(await record(nil, own: .success(try Self.own(#""ssh": null"#, machine: "hub-2"))) == (.unknown, 1))
        #expect(await record(nil, own: .success(nil)) == (.unknown, 1))
        #expect(await record(nil, own: .failure(NoAnswer())) == (.unknown, 1))
    }

    @Test func withNoConnectionOnRecordThisMacHasTheOneThatItKeeps() {
        let kept = InstallTarget(host: "100.64.0.9")
        #expect(OwnerKeyPlan.reach(without: .none, kept: nil) == .none)
        #expect(OwnerKeyPlan.reach(without: .unknown, kept: nil) == .unknown)
        #expect(OwnerKeyPlan.reach(without: .none, kept: kept) == .target(kept))
        #expect(OwnerKeyPlan.reach(without: .unknown, kept: kept) == .target(kept))
    }

    /// The page's bytes: the record of a machine of any name that the list of servers can have, and none from a page
    /// that names none or whose record is not one. A page of another database is no answer.
    @Test func theHubsOwnRecordIsReadFromTheVaultsPage() throws {
        func page(_ hub: String?, db: String = "db") -> Data {
            Data(#"{"db": "\#(db)", "fleet": "0123456789abcdef", "machines": []\#(hub.map { #", "hub": \#($0)"# } ?? "")}"#.utf8)
        }
        let record = #"{"machine": "Hub_EU.1", "address": "100.64.0.2", "ssh": {"user": "root", "port": 22}}"#
        let found = try #require(try HubClient.ownServer(in: page(record), database: "db"))
        #expect(found.machine == "Hub_EU.1" && found.reach == MachineReach(address: "100.64.0.2", user: "root", port: 22))
        #expect(OwnerKeyPlan.record(server: "Hub_EU.1", listed: nil, listRead: true, own: found, ownRead: true) == .reach(found.reach))
        #expect(try HubClient.ownServer(in: page(nil), database: "db") == nil)
        #expect(try HubClient.ownServer(in: page("null"), database: "db") == nil)
        #expect(try HubClient.ownServer(in: page(#"{"machine": 7}"#), database: "db") == nil)
        #expect(try HubClient.ownServer(in: page(#"{"machine": "hub-1", "address": "100.64.0.2", "ssh": {"user": "root", "port": "22"}}"#), database: "db") == nil)
        let noSSH = try #require(try HubClient.ownServer(in: page(#"{"machine": "hub-1", "address": "100.64.0.2", "ssh": null}"#), database: "db"))
        #expect(noSSH.reach.onRecord == nil)
        #expect(throws: (any Error).self) { try HubClient.ownServer(in: page(record, db: "other"), database: "db") }
        #expect(throws: (any Error).self) { try HubClient.ownServer(in: Data("no JSON".utf8), database: "db") }
        #expect(throws: (any Error).self) { try HubClient.ownServer(in: Data(#"{"hub": \#(record)}"#.utf8), database: "db") }
    }

    @Test func aPathThatTheMacMayNotReadIsNeverRead() async throws {
        for path in ["/etc/shadow", "/root/.ssh/id_ed25519", "/home/fleet/../../etc/owner-key.proof", nil] as [String?] {
            state.proofFile = path
            await #expect(throws: OwnerMacKeyRegistration.Failure.noPath) {
                try await register { _ in Issue.record("it read \(path ?? "nothing")"); return "" }
            }
        }
        #expect(OwnerMacKey.read(hub: hub, home: home) == nil)
        #expect(state.sha == nil)
    }

    @Test func whatIsNoValueIsNotSentAndAWrongValueRegistersNothing() async throws {
        await #expect(throws: OwnerMacKeyRegistration.Failure.noValue) {
            try await register { _ in "root:$6$salt$hash:19000:0:99999:7:::\n" }
        }
        await #expect(throws: OwnerMacKeyRegistration.Failure.noValue) {
            try await register { _ in throw URLError(.cannotConnectToHost) }
        }
        #expect(state.seen.count == 2)          // the first call each time, and no second one
        await #expect(throws: OwnerMacKeyRegistration.Failure.noValue) {
            try await register { _ in String(repeating: "z", count: 43) }      // the right shape, and no mark
        }
        #expect(state.seen.count == 3)
        await #expect(throws: OwnerMacKeyRegistration.Failure.refused) {
            try await register { _ in "founderizer-proof:" + String(repeating: "z", count: 43) }
        }
        #expect(OwnerMacKey.read(hub: hub, home: home) == nil)
        // The key of a registration that the hub refused still waits: the same call can have arrived a first time,
        // and then the hub holds it. Here the hub holds none, so a read with it is refused as not expected, and the
        // next registration writes its own key over it.
        let waits = try #require(OwnerMacKey.waiting(hub: hub, home: home))
        #expect(state.sha == nil)
        #expect(status(try await read()) == 200)
        #expect(OwnerMacKey.read(hub: hub, home: home) == nil)
        let proof = state.proof
        try await register { _ in "founderizer-proof:" + proof }
        #expect(OwnerMacKey.read(hub: hub, home: home) != waits)
        #expect(OwnerMacKey.waiting(hub: hub, home: home) == nil)
    }

    /// A registration whose answer was lost, on a Mac that has a key from before (the hub got another one since):
    /// the hub holds the key that waits. The key from before is refused once, and then the key that waits goes and
    /// becomes the key. No second registration is needed, and the app does not send the old key for ten minutes.
    @Test func theKeyThatWaitsGoesWhenTheHubRefusedTheKeyFromBefore() async throws {
        try OwnerMacKey.keep(Self.other, hub: hub, home: home)
        let proof = state.proof
        state.loses = 1
        await #expect(throws: OwnerMacKeyRegistration.Failure.noAnswer) {
            try await register { _ in "founderizer-proof:" + proof }
        }
        let waits = try #require(OwnerMacKey.waiting(hub: hub, home: home))
        #expect(state.sha == OwnerMacKey.digest(waits))
        #expect(OwnerMacKey.read(hub: hub, home: home) == Self.other)
        #expect(status(try await read()) == 403)                        // the key from before, once
        #expect(OwnerMacKey.refused(hub: hub) == .mismatch)
        #expect(status(try await read()) == 200)                        // then the key that waits
        #expect(state.seen.suffix(2).map(\.bearer) == [Self.other, waits])
        #expect(OwnerMacKey.read(hub: hub, home: home) == waits)
        #expect(OwnerMacKey.waiting(hub: hub, home: home) == nil)
        #expect(OwnerMacKey.refused(hub: hub) == nil)
    }

    /// A Mac that cannot write its key sends the hub nothing: the hub must never hold the SHA-256 of a key that no
    /// program has.
    @Test func aKeyThatCannotBeWrittenIsNotRegistered() async throws {
        let blocked = home.appendingPathComponent(".founderizer")
        try Data("a file where the folder must be".utf8).write(to: blocked)
        let proof = state.proof
        await #expect(throws: OwnerMacKeyRegistration.Failure.notKept) {
            try await register { _ in "founderizer-proof:" + proof }
        }
        #expect(state.seen.count == 1)                                  // the first call only
        #expect(state.sha == nil)
    }

    // ------------------------------------------------------------ the claim of a new hub

    @Test func theClaimCarriesTheShaOfANewKeyAndTheMacKeepsItWhenTheInstallerDoes() async throws {
        let address = TestHub.address()
        let claim = URL(string: "http://\(address):8765/claim")!, hub = URL(string: "http://\(address):8765")!
        let state = KeyedHub.hub(address)
        try await MachineInstaller.sendClaim(code: "7KMQ2PRJ4TVW", to: claim, home: home, session: KeyedHub.session)
        let key = try #require(OwnerMacKey.read(hub: hub, home: home))
        #expect(state.seen.count == 1)
        #expect(state.seen[0].claimSha == OwnerMacKey.digest(key))
        #expect(state.seen[0].bearer == nil)
        #expect(state.sha == OwnerMacKey.digest(key))
        // The hub that starts on that address takes this Mac's calls, and not the address alone.
        let read = URLRequest(url: hub.appendingPathComponent("ui/state"))
        #expect(status(try await KeyedHub.session.hubData(for: read, home: home)) == 200)
        #expect(status(try await KeyedHub.session.data(for: read)) == 403)
    }

    @Test func aClaimWhoseAnswerWasLostKeepsItsKeyAndTheNextClaimSendsTheSameOne() async throws {
        let address = TestHub.address()
        let claim = URL(string: "http://\(address):8765/claim")!, hub = URL(string: "http://\(address):8765")!
        let state = KeyedHub.hub(address)
        state.loses = 1
        await #expect(throws: (any Error).self) {
            try await MachineInstaller.sendClaim(code: "7KMQ2PRJ4TVW", to: claim, home: home, session: KeyedHub.session)
        }
        let waits = try #require(OwnerMacKey.waiting(hub: hub, home: home))
        #expect(state.sha == OwnerMacKey.digest(waits))                 // the listener took it
        #expect(OwnerMacKey.read(hub: hub, home: home) == nil)
        try await MachineInstaller.sendClaim(code: "7KMQ2PRJ4TVW", to: claim, home: home, session: KeyedHub.session)
        #expect(state.seen.map(\.claimSha) == [OwnerMacKey.digest(waits), OwnerMacKey.digest(waits)])
        #expect(OwnerMacKey.read(hub: hub, home: home) == waits)
        #expect(OwnerMacKey.waiting(hub: hub, home: home) == nil)
    }

    /// A code that the listener refuses (a wrong letter): the key still waits, and the claim with the right code
    /// sends the same one. The hub never gets the SHA-256 of a key that this Mac threw away.
    @Test func aClaimThatTheListenerRefusesKeepsItsKeyForTheNextOne() async throws {
        let address = TestHub.address()
        let claim = URL(string: "http://\(address):8765/claim")!, hub = URL(string: "http://\(address):8765")!
        let state = KeyedHub.hub(address)
        state.refusesClaim = true
        await #expect(throws: (any Error).self) {
            try await MachineInstaller.sendClaim(code: "7KMQ2PRJ4TVX", to: claim, home: home, session: KeyedHub.session)
        }
        let waits = try #require(OwnerMacKey.waiting(hub: hub, home: home))
        #expect(state.sha == nil)
        #expect(OwnerMacKey.read(hub: hub, home: home) == nil)
        state.refusesClaim = false
        try await MachineInstaller.sendClaim(code: "7KMQ2PRJ4TVW", to: claim, home: home, session: KeyedHub.session)
        #expect(state.seen.map(\.claimSha) == [OwnerMacKey.digest(waits), OwnerMacKey.digest(waits)])
        #expect(OwnerMacKey.read(hub: hub, home: home) == waits)
        #expect(OwnerMacKey.waiting(hub: hub, home: home) == nil)
    }

    @Test func anInstallerFromBeforeTheKeyLeavesTheMacWithNone() async throws {
        let address = TestHub.address()
        let state = KeyedHub.hub(address)
        state.keeps = false
        try await MachineInstaller.sendClaim(code: "7KMQ2PRJ4TVW", to: URL(string: "http://\(address):8765/claim")!,
                                             home: home, session: KeyedHub.session)
        #expect(state.seen.count == 1)
        #expect(OwnerMacKey.read(hub: URL(string: "http://\(address):8765")!, home: home) == nil)
        #expect(OwnerMacKey.waiting(hub: URL(string: "http://\(address):8765")!, home: home) == nil)
    }

    // ------------------------------------------------------------ every call of the hub's owner API

    /// **No hub client sends a request past the key.** A client that calls the hub sends through `hubData`, or signs
    /// the request with `OwnerMacKey.authorized` where it moves a file. A new file that sends with `URLSession` is
    /// named here, with whom it calls, or it goes through the key. The scan reads each file whole, so a send that is
    /// broken over two lines or written with other spaces is seen too, in FleetCore, in the Mac app, in the program
    /// inside the app and in the iPhone app.
    @Test func everyFileThatSendsARequestIsNamedOrGoesThroughTheKey() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Files whose requests go to somebody that is no hub's owner API, and to whom.
        let elsewhere: [String: String] = [
            "ProblemReport.swift": "our own site, for a report", "FleetOnTailscale.swift": "GET /health, which every caller reads",
            "ErrorReports.swift": "our own site, for error reports (its hub calls are in HubClient.swift)",
            "TailscaleFleetKey.swift": "Tailscale's API", "AppUpdateInstall.swift": "the release channel",
            "MachineInstaller.swift": "the claim's listener, with the key's SHA-256", "AppUpdate.swift": "the release channel",
            "EntitlementClaim.swift": "our own site", "PrivateNetwork.swift": "Tailscale's API",
            "MacInstallerLink.swift": "a Mac's installer on the local network", "GitHubAppKey.swift": "GitHub's API",
            "GitHubManifest.swift": "GitHub's API", "MacNetwork.swift": "Tailscale's download", "CloudServers.swift": "a cloud's API",
            "OwnerMacKey.swift": "the key itself: hubData and the registration",
            "GuideProgram.swift": "an AI provider's own download of its program",
            "SellerModels.swift": "a seller's public list of its models (OpenCode Go, OpenRouter, Ollama), with no key",
            "OwnerHub.swift": "the program inside the app, which reads the key for its own request (OwnerKeyTests)",
        ]
        #expect(Self.bareSends(in: "session.data(for: request)") == 1)
        #expect(Self.bareSends(in: "try await session\n    .data(\n        for: request)") == 1)
        #expect(Self.bareSends(in: "x.data(for:request); y.upload( for: r, fromFile: f); z.bytes(from: u); s.dataTask(with: r)") == 4)
        #expect(Self.bareSends(in: "URLSession.shared.download(from: url)") == 1)
        #expect(Self.bareSends(in: "session.hubData(for: request); t.upload(for: OwnerMacKey.authorized(request), fromFile: f)") == 0)
        // A read that takes its answer as a stream goes through `hubBytes`, also when it signs its request: its
        // callers compare the answer's address with their own request's, and only `hubBytes` gives it back so.
        #expect(Self.bareSends(in: "transfer.bytes(for: OwnerMacKey.authorized(request))") == 1)
        #expect(Self.bareSends(in: "transfer.hubBytes(for: request)") == 0)
        #expect(Self.bareSends(in: "defaults.data(forKey: key); pasteboard.data(forType: kind)") == 0)
        #expect(Self.bareSends(in: "try await self.data(for: request)") == 1)
        #expect(Self.bareSends(in: "try await self.data(for: request)", ownSend: true) == 0)
        #expect(Self.bareSends(in: "try await self.data(for: request); session.data(for: request)", ownSend: true) == 1)
        // A call that names the key's folder or its lookup is a test's: in the app, a `home: nil` would send no key.
        #expect(Self.keyOverrides(in: "session.hubData(for: request)") == 0)
        #expect(Self.keyOverrides(in: "t.upload(for: OwnerMacKey.authorized(request), fromFile: file(home: home))") == 0)
        #expect(Self.keyOverrides(in: "session.hubData(for: request, home: nil)") == 1)
        #expect(Self.keyOverrides(in: "session.hubData(\n    for: build(a, b: (c)),\n    lookup: { _ in nil })") == 1)
        #expect(Self.keyOverrides(in: "OwnerMacKey.authorized(request, home: other); x.hubData(for: r); y.hubData(for: r, home: h)") == 2)
        #expect(Self.keyOverrides(in: "transfer.hubBytes(for: request, home: nil); transfer.hubBytes(for: request)") == 1)
        var bare: [String] = [], overrides: [String] = []
        for folder in ["Sources/FleetCore", "Sources/Founderizer", "Sources/FleetOwnerAPI", "Sources/FleetImport",
                       "Sources/FleetSetupService", "Sources/FounderizerCLI", "Sources/FounderizerInstaller", "ios/Sources"] {
            let at = app.appendingPathComponent(folder)
            for file in ((try? FileManager.default.contentsOfDirectory(atPath: at.path)) ?? []).sorted()
            where file.hasSuffix(".swift") {
                let text = try String(contentsOf: at.appendingPathComponent(file), encoding: .utf8)
                if file != "OwnerMacKey.swift", Self.keyOverrides(in: text) > 0 { overrides.append("\(folder)/\(file)") }
                guard elsewhere[file] == nil else { continue }
                // The phone's client has one send of its own, `data(for:)`, which goes through `hubData`: its calls
                // of that method are no sends of a session. In every other file a `self.data(for:)` is one.
                let found = Self.bareSends(in: text, ownSend: file == "MobileClient.swift")
                if found > 0 { bare.append("\(folder)/\(file): \(found)") }
            }
        }
        #expect(bare.isEmpty, "these files send a request with no key of this Mac: \(bare)")
        #expect(overrides.isEmpty, "these files name the key's folder or its lookup at a call: \(overrides)")
    }

    /// The sends of a text that do not sign their request: each `data`, `bytes`, `upload` and `download` of a session
    /// with `for:` or `from:`, and each task of a session, whose argument is not `OwnerMacKey.authorized(...)`.
    /// `ownSend`: the file has a `data(for:)` of its own, so its `self.data(for:)` is no send of a session.
    static func bareSends(in text: String, ownSend: Bool = false) -> Int {
        let sends = try! NSRegularExpression(
            pattern: (ownSend ? "(?<!self)" : "")
                + #"\.\s*(data|upload|download)\s*\(\s*(for|from)\s*:(?!\s*OwnerMacKey\.authorized\()|\.\s*bytes\s*\(\s*(for|from)\s*:|\.\s*(data|upload|download|webSocket|stream)Task\s*\("#)
        return sends.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// The calls of `hubData`, of `hubBytes` and of `OwnerMacKey.authorized` in a text that have a `home:` or a `lookup:` among
    /// their own arguments (not inside an argument's own brackets).
    static func keyOverrides(in text: String) -> Int {
        let calls = try! NSRegularExpression(pattern: #"(\.hubData|\.hubBytes|OwnerMacKey\.authorized)\s*\("#)
        let label = try! NSRegularExpression(pattern: #"(^|,)\s*(home|lookup)\s*:"#)
        var count = 0
        for match in calls.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let from = Range(match.range, in: text)?.upperBound else { continue }
            // The call's own arguments, with what stands inside brackets of an argument left out.
            var depth = 1, own = ""
            for character in text[from...] {
                if "([{".contains(character) { depth += 1 } else if ")]}".contains(character) { depth -= 1 }
                if depth == 0 { break }
                if depth == 1, !")]}".contains(character) { own.append(character) }
            }
            if label.firstMatch(in: own, range: NSRange(own.startIndex..., in: own)) != nil { count += 1 }
        }
        return count
    }
}

/// The hosts that a test's lookup was asked for.
final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String] = []
    func add(_ host: String) { lock.withLock { hosts.append(host) } }
    var all: [String] { lock.withLock { hosts } }
}
