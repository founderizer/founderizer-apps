import CryptoKit
import Foundation

/// **This Mac's own key for one hub** (`hub.py`, owner feature `owner_key`; the owner, 14 November 2026: "it needs to
/// be tested and verified", then his answers "A file in ~/.founderizer" and "By itself, over SSH").
///
/// The hub knew the owner's Mac by its address alone. A VM or a container on that Mac leaves through the Mac's own
/// address, so the hub took such a guest for the owner. So the Mac proves itself with its address **and** a key: 32
/// random bytes that it makes itself, of which the hub keeps only the SHA-256, as it does for an agent and for an
/// owner device.
///
/// **One file for each hub**, `~/.founderizer/owner-keys/<address>_<port>`, mode 600 in a folder of mode 700: the
/// folder that this app, its program `founderizer-cli` and the owner's MCP server (`owner_mcp.py`) share already. Each
/// of them reads the file at each call, so a key that one of them registered counts for the others at once. It has the
/// protection of the app's own SSH key (`AppSSHKey`), which is a file of this user too. The file has the hub's numeric
/// address in its name, however a program writes the hub's address (`place`).
///
/// **A key waits beside its place** (`<address>_<port>.pending`) from before the call that tells a hub its SHA-256
/// until the hub's answer, so that an answer that is lost loses no key: the next call carries the key that waits, and
/// a hub that takes it makes it the key.
///
/// **What it does not guard against:** a program that runs on this Mac as this user reads the file, as it reads the
/// SSH keys. The key guards against a guest behind the Mac, which has the Mac's address and none of its files.
public enum OwnerMacKey {
    /// The hub's feature name: a hub that lists it takes a key and has `POST /ui/owner/key`.
    public static let feature = "owner_key"
    /// The header of a claim that carries the key's SHA-256 beside the code (`hubsetup.py` `OWNER_KEY_HEADER`).
    public static let claimHeader = "X-Fleet-Owner-Key-Sha256"
    /// The header of the claim's answer, which says "kept" when the installer keeps the SHA-256 (`OWNER_KEY_KEPT`).
    public static let claimKept = "X-Fleet-Owner-Key"

    /// The hub's three refusals that are about this key (`auth` in a 403).
    public enum Refusal: String, Sendable {
        /// The hub holds a key of this Mac, and the call carried none.
        case required = "owner_key_required"
        /// The hub holds another key than the call carried.
        case mismatch = "owner_key_mismatch"
        /// The hub holds no key of this Mac (a fleet from before the key) and refuses a bearer, as every hub did.
        case notExpected = "key_not_expected"
    }

    // ------------------------------------------------------------ where the key is

    /// The home folder that holds `.founderizer`: this user's on a Mac. In the iPhone simulator it is the Mac user's
    /// (`SIMULATOR_HOST_HOME`), because a simulator is a program of that Mac and calls from the Mac's address. A real
    /// iPhone has none: it is an owner device with its own key (`DeviceKey`).
    ///
    /// **A test run has none either.** A test that is about this key gives a home of its own; every other test of the
    /// package sends its requests to made-up hubs, and must neither read this user's keys nor ask a resolver for a
    /// made-up name because this user's folder holds a key of the same port.
    public static var home: URL? {
        if inTestRun { return nil }
        #if os(macOS)
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #elseif targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        #else
        return nil
        #endif
    }

    /// Whether this process is a test run: the test library is loaded, which no shipped program has.
    static let inTestRun = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// `<host>_<port>` of a hub's address as it is written, in the letters of a file name, or nil for an address with
    /// no host. For a hub that is written as a number it is the name of the key's file (`owner_mcp.py`
    /// `owner_key_file`, and the claim's own script in `hubsetup.py`, give the same name). What a hub said of this
    /// Mac's key is remembered under it (`Said`).
    public static func name(hub: URL) -> String? {
        guard let host = hub.host?.lowercased(), !host.isEmpty else { return nil }
        return name(host: host, port: port(hub))
    }

    static func port(_ hub: URL) -> Int { hub.port ?? (hub.scheme?.lowercased() == "https" ? 443 : 80) }

    static func name(host: String, port: Int) -> String {
        let letters = host.lowercased().unicodeScalars.map { scalar -> Character in
            let plain = (scalar.value >= 0x61 && scalar.value <= 0x7A) || (scalar.value >= 0x30 && scalar.value <= 0x39)
                || scalar == "." || scalar == "-"
            return plain ? Character(scalar) : "-"
        }
        return String(letters) + "_\(port)"
    }

    static func folder(home: URL) -> URL {
        home.appendingPathComponent(".founderizer", isDirectory: true).appendingPathComponent("owner-keys", isDirectory: true)
    }

    /// A key as this Mac and the hub's other clients write one: 32 to 128 letters of base64url.
    static func isKey(_ text: String) -> Bool {
        text.range(of: "^[A-Za-z0-9_-]{32,128}$", options: .regularExpression) != nil
    }

    /// The key in `file`, or nil: at most 256 bytes of a regular file, read with no wait (`KeptFile`). Before, the
    /// file was read whole, whatever it was, and its size was checked after that; this read runs for each request
    /// of the app to its hub. The limit is the one from before: a key's file has at most 128 letters and a line end.
    static func key(in file: URL) -> String? {
        guard let data = KeptFile.bytes(of: file, atMost: 256),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              isKey(text) else { return nil }
        return text
    }

    /// What the system's lookup gave for a name, kept for a minute (ten seconds for a name that it does not know), so
    /// that an app which calls its hub by a name asks the resolver once a minute and not at each request.
    private static let lookups = NSCondition()
    nonisolated(unsafe) private static var lookedUp: [String: (address: String?, until: Date, answered: Date?)] = [:]
    /// How long the number of a name's last answer stands in for lookups that fail.
    static let lookupKept: TimeInterval = 600
    nonisolated(unsafe) private static var asking: Set<String> = []
    /// How long a caller waits for another caller's lookup of a name that has no answer yet.
    static let lookupWait: TimeInterval = 3

    /// The numeric address of a host name through the system's own lookup, or nil (`chosen`).
    ///
    /// **One thread at most asks the resolver for one name.** A lookup can take seconds on a network that is down,
    /// and every request of the app comes through here. While one caller asks, each other caller gets the number
    /// that was known before. For a name with no number yet (the first requests of a run, which start together),
    /// the other callers wait for that one answer, three seconds at most: with nil at once, each of them would send
    /// its request with no key, and the hub would refuse it.
    ///
    /// **One lookup that fails does not take a name's number away.** The resolver of this process can fail for a
    /// moment (after a wake) while the connection still finds the hub: with the number gone, each request would go
    /// with no key for ten seconds, and the hub would refuse it. So the number of the last answer stands in for ten
    /// minutes at most, and the resolver is asked again every ten seconds. The key's file has that same number in
    /// its name, so the key still goes only there.
    public static let systemLookup: @Sendable (String) -> String? = { host in
        lookedUp(host, ask: resolved)
    }

    /// `systemLookup` with the lookup itself given: `ask` gives every address of a name. For a test.
    static func lookedUp(_ host: String, ask: (String) -> [String], wait: TimeInterval = lookupWait,
                         clock: () -> Date = { Date() }) -> String? {
        let now = clock()
        lookups.lock()
        if let kept = lookedUp[host], kept.until > now {
            lookups.unlock()
            return kept.address
        }
        if asking.contains(host) {
            if let before = lookedUp[host]?.address {
                lookups.unlock()
                return before
            }
            let until = now.addingTimeInterval(wait)
            while asking.contains(host), lookups.wait(until: until) {}
            let answered = lookedUp[host]?.address
            lookups.unlock()
            return answered
        }
        asking.insert(host)
        lookups.unlock()
        let found = chosen(ask(host))
        lookups.lock()
        let then = clock(), before = lookedUp[host]
        var address = found, answered: Date? = found == nil ? nil : then
        if found == nil, let last = before?.address, let at = before?.answered, then.timeIntervalSince(at) < lookupKept {
            address = last
            answered = at
        }
        lookedUp[host] = (address, then.addingTimeInterval(found == nil ? 10 : 60), answered)
        asking.remove(host)
        lookups.broadcast()
        lookups.unlock()
        return address
    }

    /// Every address of a host name, from the system's own lookup.
    private static func resolved(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var found: UnsafeMutablePointer<addrinfo>?
        var all: [String] = []
        if getaddrinfo(host, nil, &hints, &found) == 0, let found {
            defer { freeaddrinfo(found) }
            var next: UnsafeMutablePointer<addrinfo>? = found
            while let one = next {
                var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(one.pointee.ai_addr, one.pointee.ai_addrlen, &text, socklen_t(text.count), nil, 0,
                               NI_NUMERICHOST) == 0 {
                    all.append(String(cString: text).lowercased())
                }
                next = one.pointee.ai_next
            }
        }
        return all
    }

    /// Whether an address is one of the fleet's private network: 100.64.0.0/10, or Tailscale's own IPv6 range
    /// fd7a:115c:a1e0::/48. Such an address is one machine's, and the way to it proves the machine. A loopback
    /// address, a link-local one and an address of a bridge are on every machine.
    static func isOfFleetNetwork(_ address: String) -> Bool {
        var four = in_addr(), six = in6_addr()
        if inet_pton(AF_INET, address, &four) == 1 {
            return withUnsafeBytes(of: &four) { $0[0] == 100 && (64...127).contains($0[1]) }
        }
        if inet_pton(AF_INET6, address, &six) == 1 {
            return withUnsafeBytes(of: &six) { Array($0.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] }
        }
        return false
    }

    /// The one address of a name's addresses that names its key's file, the same one for the same set in any order:
    /// an address of the fleet's private network first (100.64.0.0/10, as a hub's own address in `team.json` is
    /// one), else the lowest IPv4 address, else the lowest of the others. So a name with two addresses has one key
    /// file, and not one that comes and goes with the resolver's order.
    static func chosen(_ addresses: [String]) -> String? {
        func four(_ text: String) -> [UInt8]? {
            var address = in_addr()
            guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
            return withUnsafeBytes(of: &address) { Array($0) }
        }
        let fours = addresses.compactMap { text in four(text).map { (text, $0) } }.sorted { $0.1.lexicographicallyPrecedes($1.1) }
        if let fleet = fours.first(where: { $0.1[0] == 100 && (64...127).contains($0.1[1]) }) { return fleet.0 }
        return fours.first?.0 ?? addresses.compactMap(canonical).sorted().first
    }

    /// Whether a host is written as an address, which needs no lookup.
    static func isAddress(_ host: String) -> Bool { canonical(host) != nil }

    /// An address in the one spelling that names a key's file, or nil for what is no address: IPv4 as it is written,
    /// IPv6 as the system writes it. So `fd7a:115c:a1e0:0:0:0:0:1` and `fd7a:115c:a1e0::1` are one file
    /// (`canonical_address` in `owner_mcp.py`).
    static func canonical(_ host: String) -> String? {
        var four = in_addr(), six = in6_addr()
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, host, &four) == 1, inet_ntop(AF_INET, &four, &text, socklen_t(text.count)) != nil {
            return String(cString: text)
        }
        if inet_pton(AF_INET6, host, &six) == 1, inet_ntop(AF_INET6, &six, &text, socklen_t(text.count)) != nil {
            return String(cString: text).lowercased()
        }
        return nil
    }

    /// **One hub address has one key file, named by its number.** A hub's address is written in two ways: as a number
    /// (the claim's own line, `100.64.0.9`) and as a name of the private network. The key's file has the number in
    /// its name, whichever way a program writes the address: a name is looked up first. So a claim that wrote the
    /// file under the number and an app that calls the hub by its name read one file, and there is no second file of
    /// another spelling that could hold an older key. The key goes only to a host whose own address named the file.
    ///
    /// The file's name for `hub`, or nil: for a number, its own; for a name, the number that the lookup gives. **A
    /// name that has no number now has no key**: nothing is read and nothing is written for it, and this Mac registers
    /// no key until the lookup answers (`holding`, `OwnerKeyPlan.step`).
    static func place(hub: URL, lookup: (String) -> String?) -> String? {
        guard let host = hub.host?.lowercased(), !host.isEmpty else { return nil }
        if let address = canonical(host) { return name(host: address, port: port(hub)) }
        guard let address = lookup(host).flatMap(canonical) else { return nil }
        return name(host: address, port: port(hub))
    }

    /// The file of this Mac's key for `hub`: where a key is written and read.
    public static func file(hub: URL, home: URL? = OwnerMacKey.home, lookup: (String) -> String? = systemLookup) -> URL? {
        guard let home, let name = place(hub: hub, lookup: lookup) else { return nil }
        return folder(home: home).appendingPathComponent(name)
    }

    /// The file that holds a key for `hub` now (with `pending`, the key that waits), or nil. For a hub that is called
    /// by a name, nothing is looked up while the folder holds no file of that port: there is nothing to find.
    static func found(hub: URL, home: URL?, pending: Bool = false, lookup: (String) -> String? = systemLookup) -> URL? {
        guard let home, let host = hub.host?.lowercased(), !host.isEmpty else { return nil }
        let folder = folder(home: home), ending = pending ? ".pending" : ""
        if !isAddress(host) {
            let tail = "_\(port(hub))" + ending
            let any = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .contains { $0.hasSuffix(tail) && !$0.hasPrefix(".") }
            guard any else { return nil }
        }
        guard let name = place(hub: hub, lookup: lookup) else { return nil }
        let file = folder.appendingPathComponent(name + ending)
        return key(in: file) != nil ? file : nil
    }

    /// This Mac's key for `hub`, or nil while it has none. Read at each call.
    public static func read(hub: URL, home: URL? = OwnerMacKey.home, lookup: (String) -> String? = systemLookup) -> String? {
        found(hub: hub, home: home, lookup: lookup).flatMap(key(in:))
    }

    /// The key that waits for the answer of the hub at `hub`, or nil.
    static func waiting(hub: URL, home: URL? = OwnerMacKey.home, lookup: (String) -> String? = systemLookup) -> String? {
        found(hub: hub, home: home, pending: true, lookup: lookup).flatMap(key(in:))
    }

    /// A new key: 32 bytes of the system's random source as base64url with no padding, 43 letters.
    public static func make(random: (Int) throws -> Data = AgeSeal.secureRandom) throws -> String {
        try random(32).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// The SHA-256 of a key's text in lower-case hex: all that a hub ever gets of it.
    public static func digest(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public struct NotKept: LocalizedError, Equatable {
        public let reason: String
        public var errorDescription: String? { String(l10n: "This Mac could not keep its key for the hub: \(reason)") }
    }

    /// One key file, in place of anything at `file`: made beside its place with mode 600 at its creation (`open` with
    /// that mode and `O_EXCL`, so it is at no moment readable by another user, and it follows no link), then moved
    /// there, so no reader meets half a key.
    private static func write(_ key: String, to file: URL) throws {
        let manager = FileManager.default, folder = file.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        } catch {
            throw NotKept(reason: error.localizedDescription)
        }
        let part = folder.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString)")
        let handle = open(part.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard handle >= 0 else { throw NotKept(reason: String(cString: strerror(errno))) }
        defer { unlink(part.path) }
        let bytes = Array((key + "\n").utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(handle, $0.baseAddress, $0.count) }
        let closed = close(handle)
        guard written == bytes.count, closed == 0 else { throw NotKept(reason: String(cString: strerror(errno))) }
        guard rename(part.path, file.path) == 0 else { throw NotKept(reason: String(cString: strerror(errno))) }
    }

    private static func forgetSaid(_ names: String?...) {
        lock.withLock {
            for case let name? in names { said.refused[name] = nil; said.noKey[name] = nil; said.waitsRefused[name] = nil }
        }
    }

    /// The place of a key of `hub`: its file, and the file of the key that waits.
    private static func places(hub: URL, home: URL?, lookup: (String) -> String?) -> (key: URL, waits: URL)? {
        guard let home, let name = place(hub: hub, lookup: lookup) else { return nil }
        return (folder(home: home).appendingPathComponent(name), folder(home: home).appendingPathComponent(name + ".pending"))
    }

    /// Keeps `key` as this Mac's key for `hub`, in place of any earlier one. The key that waited goes.
    public static func keep(_ key: String, hub: URL, home: URL? = OwnerMacKey.home,
                            lookup: (String) -> String? = systemLookup) throws {
        guard isKey(key), let place = places(hub: hub, home: home, lookup: lookup) else { throw NotKept(reason: "no place") }
        try write(key, to: place.key)
        unlink(place.waits.path)
        // What a hub said of the key from before says nothing of this one.
        forgetSaid(name(hub: hub), place.key.lastPathComponent)
    }

    /// Keeps `key` as the key that waits for the answer of the hub at `hub`: written **before** the call that tells the
    /// hub its SHA-256, so that the hub never holds the SHA-256 of a key that this Mac does not have.
    public static func keepWaiting(_ key: String, hub: URL, home: URL? = OwnerMacKey.home,
                                   lookup: (String) -> String? = systemLookup) throws {
        guard isKey(key), let place = places(hub: hub, home: home, lookup: lookup) else { throw NotKept(reason: "no place") }
        try write(key, to: place.waits)
    }

    /// **The hub took `key`: it is this Mac's key now.** The hub holds its SHA-256, so it is the key whatever waits in
    /// the file: two programs of this Mac can register at one time, and the one whose key the hub took must keep it
    /// also when the other one's key waits there by then. A key that cannot be written stays as it is.
    static func promote(_ key: String, hub: URL, home: URL? = OwnerMacKey.home, lookup: (String) -> String? = systemLookup) {
        guard let place = places(hub: hub, home: home, lookup: lookup) else { return }
        if self.key(in: place.key) != key, (try? write(key, to: place.key)) == nil { return }
        if self.key(in: place.waits) == key { unlink(place.waits.path) }
        forgetSaid(name(hub: hub), place.key.lastPathComponent)
    }

    /// The key that waited for the hub at `hub` goes, when it is `key`: the hub answered, and it keeps no such key.
    /// A key of another program that waits there by then stays.
    static func forgetWaiting(_ key: String, hub: URL, home: URL? = OwnerMacKey.home,
                              lookup: (String) -> String? = systemLookup) {
        guard let place = places(hub: hub, home: home, lookup: lookup), self.key(in: place.waits) == key else { return }
        unlink(place.waits.path)
    }

    // ------------------------------------------------------------ the key on a call

    /// What the hubs said of this key since this program started, by a hub's file name.
    private struct Said {
        /// The key that a hub refused as not expected: it is sent to that hub no more while it is this Mac's key.
        var noKey: [String: String] = [:]
        /// The hub's last refusal of a call for want of the right key, until a call passes.
        var refused: [String: Refusal] = [:]
        /// The key that waited beside this Mac's key, and that the hub refused too, with the time of that refusal:
        /// it is not sent again for `waitsRetry`.
        var waitsRefused: [String: (key: String, at: Date)] = [:]
    }
    /// After this time a key that waits and that the hub refused goes once more, while the hub still refuses the
    /// key: a hub can take a registration after it answered the first call with that key.
    static let waitsRetry: TimeInterval = 30
    private static let lock = NSLock()
    nonisolated(unsafe) private static var said = Said()

    /// `request` with this Mac's key for its hub as the bearer, when the Mac has one and the request carries no
    /// credential of its own (a phone's read carries the phone's key). With no key, the key that waits for that hub's
    /// answer goes. A request to anything that is no hub of this Mac has no key file, and so no key. A hub that
    /// answered that it expects none gets none (`took`). A request that carries the key goes to the hub's number
    /// (`signing`), so its address can be another one than `request`'s.
    public static func authorized(_ request: URLRequest, home: URL? = OwnerMacKey.home,
                                  lookup: (String) -> String? = systemLookup) -> URLRequest {
        signing(request, home: home, lookup: lookup).wire
    }

    /// What one request to a hub carries: the request as it goes, and this Mac's key in it, or nil.
    ///
    /// **One lookup decides the key and where it goes.** For a hub that is called by a name, the name is looked up
    /// once: the key is the one in the file of that number, and the request goes to that number, never to the name
    /// again. A connection looks a name up by itself, and that second answer can be another host than the first: a
    /// name that somebody else controls could answer the hub's number to the one and its own host to the other, and
    /// get the key. So the key only ever goes to the number that named its file. A request with no key goes as it is.
    static func signing(_ request: URLRequest, home: URL? = OwnerMacKey.home, lookup: (String) -> String? = systemLookup,
                        now: Date = Date()) -> (wire: URLRequest, key: String?) {
        guard request.value(forHTTPHeaderField: "Authorization") == nil, let url = request.url, let name = name(hub: url),
              let host = url.host?.lowercased(), let home else { return (request, nil) }
        let folder = folder(home: home), port = port(url)
        var address = canonical(host) ?? ""
        if address.isEmpty {
            // Nothing is looked up while the folder holds no file of that port: there is nothing to find.
            let tail = "_\(port)"
            guard ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .contains(where: { ($0.hasSuffix(tail) || $0.hasSuffix(tail + ".pending")) && !$0.hasPrefix(".") }),
                  let found = lookup(host).flatMap(canonical) else { return (request, nil) }
            address = found
        }
        let file = self.name(host: address, port: port)
        let held = key(in: folder.appendingPathComponent(file)), waits = key(in: folder.appendingPathComponent(file + ".pending"))
        // The hub refused this Mac's key, and a key waits for that hub's answer: the hub can hold the key that waits
        // (a registration whose answer was lost, beside the key from before). So that one goes, and a 2xx makes it
        // the key (`took`). When the hub refuses the key that waits too, the key is the key again: another program
        // of this Mac can have put the right one in the file since. While the hub still refuses that key, the key
        // that waits goes once more after half a minute: the hub can have taken the registration since. Else the
        // key, and the key that waits only when there is no key.
        let (refused, waitsRefused) = lock.withLock { (said.refused[name] != nil, said.waitsRefused[name]) }
        let again = waitsRefused.map { $0.key != waits || now.timeIntervalSince($0.at) >= waitsRetry } ?? true
        guard let key = (refused && again ? waits : nil) ?? held ?? waits,
              lock.withLock({ said.noKey[name] }) != key else { return (request, nil) }
        guard let numbered = numbered(url, address: address) else { return (request, nil) }
        var wire = request
        wire.url = numbered
        wire.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        return (wire, key)
    }

    /// The answer to a request that went to the hub's number, under the address that the request was written with:
    /// a caller that compares the answer's address with its own request's (a read that refuses an answer from
    /// anywhere else) sees the name that it asked. Any other answer (a redirect, no HTTP) is as it came.
    static func asAsked(_ response: URLResponse, wire: URLRequest, request: URLRequest) -> URLResponse {
        guard let http = response as? HTTPURLResponse, let asked = request.url, wire.url != asked, http.url == wire.url,
              let headers = http.allHeaderFields as? [String: String],
              let renamed = HTTPURLResponse(url: asked, statusCode: http.statusCode, httpVersion: nil, headerFields: headers)
        else { return response }
        return renamed
    }

    /// `url` with `address`, a number, as its host: where a request that carries the key goes.
    static func numbered(_ url: URL, address: String) -> URL? {
        guard url.host?.lowercased() != address else { return url }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.host = address.contains(":") ? "[\(address)]" : address
        guard let numbered = parts.url, numbered.host.flatMap(canonical) == address else { return nil }
        return numbered
    }

    /// The hub's refusal of this key in an answer, or nil: a 403 whose JSON names one of the three in `auth`.
    public static func refusal(_ response: URLResponse, _ data: Data) -> Refusal? {
        guard (response as? HTTPURLResponse)?.statusCode == 403, data.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = object["auth"] as? String else { return nil }
        return Refusal(rawValue: auth)
    }

    /// Records what a hub answered to `sent`, the request as it went. `ours`: its bearer is this Mac's key, which
    /// `signing` put there. True when the same request must go again with no key: the hub holds no key of this Mac
    /// and refused the bearer before it did anything.
    ///
    /// **A refusal of a request that left before this Mac's key changed says nothing of the key that it has now.** In
    /// the moment of a registration, reads that left with no key come back refused after the key is kept: they are
    /// not recorded, or the app would take them for a lost key and register a second time.
    ///
    /// **Only an answer that the hub gave after its owner's rule clears a refusal**: a 2xx of a route of the owner
    /// API (`/ui/*`, and not the routes under `/ui/owner/`, which ask for no key). A 404 of a path that no route has, a
    /// 503 of a hub with no owner, and a 2xx of a route that asks nobody for a key never reached that rule. Such a
    /// 2xx to the key that waited makes it this Mac's key.
    @discardableResult
    static func took(_ sent: URLRequest, ours: Bool, answer: URLResponse, _ data: Data,
                     home: URL? = OwnerMacKey.home, lookup: (String) -> String? = systemLookup) -> Bool {
        guard let url = sent.url, let name = name(hub: url) else { return false }
        let bearer = sent.value(forHTTPHeaderField: "Authorization")
        let carried = bearer.flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        let found = refusal(answer, data)
        // The routes under /ui/owner/ are how a computer or a device gets its key: they ask nobody for this one.
        let passed = ((answer as? HTTPURLResponse)?.statusCode).map { (200..<300).contains($0) } ?? false
            && url.path.hasPrefix("/ui/") && !url.path.hasPrefix("/ui/owner/")
        if found == .required || found == .mismatch {
            let held = read(hub: url, home: home, lookup: lookup), waits = waiting(hub: url, home: home, lookup: lookup)
            // The key that waited beside this Mac's key, and the hub refused it: it goes no more (`signing`), and
            // the refusal of the key itself stands as it was.
            if let carried, held != nil, carried == waits, carried != held {
                lock.withLock { said.waitsRefused[name] = (carried, Date()) }
                return false
            }
            let now = held ?? waits
            if now != carried {
                // The request went with no key because this hub once said that it expects none, and the hub asks
                // for one now: it holds a key since then, so the next request carries this Mac's key again.
                if found == .required, carried == nil, let now {
                    lock.withLock { if said.noKey[name] == now { said.noKey[name] = nil } }
                }
                return false
            }
        }
        // The key that waits now, and the hub took a call with it: it is this Mac's key. (Never a key that a request
        // carried and that waits no more: another program can have registered a newer key since the request left.)
        if passed, ours, let carried, waiting(hub: url, home: home, lookup: lookup) == carried {
            promote(carried, hub: url, home: home, lookup: lookup)
        }
        return lock.withLock {
            switch found {
            case .notExpected?:
                guard ours, let carried else { return false }
                said.noKey[name] = carried
                return true
            case .required?, .mismatch?:
                said.refused[name] = found
                return false
            case nil:
                if passed { said.refused[name] = nil }
                return false
            }
        }
    }

    /// The hub at `hub` refused this Mac's last call for want of the right key, and no call passed since.
    public static func refused(hub: URL) -> Refusal? {
        guard let name = name(hub: hub) else { return nil }
        return lock.withLock { said.refused[name] }
    }

    /// The hub at `hub` holds no key of this Mac: it refused the key that this Mac has now as not expected. Such a
    /// hub knows the Mac by its address alone until the Mac registers its key.
    public static func notExpected(hub: URL, home: URL? = OwnerMacKey.home, lookup: (String) -> String? = systemLookup) -> Bool {
        guard let name = name(hub: hub),
              let key = read(hub: hub, home: home, lookup: lookup) ?? waiting(hub: hub, home: home, lookup: lookup)
        else { return false }
        return lock.withLock { said.noKey[name] } == key
    }

    /// What this Mac has for a hub now.
    public enum Holding: Sendable, Equatable {
        /// A key that the hub did not refuse as one that it does not expect.
        case key
        /// No such key.
        case none
        /// Nothing is known: the hub is called by a name, and the lookup gives that name no number now. The key's file
        /// has the number in its name, so nothing says whether this Mac has a key, and a new one would have no place.
        case unknown
    }

    /// What this Mac has for `hub`. It is `async` so that the app's poll never runs it on the main actor: for a hub
    /// that is called by a name, the key's file is found by a lookup of that name, which can take seconds on a
    /// network that is down.
    public static func holding(hub: URL, home: URL? = OwnerMacKey.home,
                               lookup: @Sendable (String) -> String? = systemLookup) async -> Holding {
        guard place(hub: hub, lookup: lookup) != nil else { return hub.host?.isEmpty == false ? .unknown : .none }
        return read(hub: hub, home: home, lookup: lookup) != nil && !notExpected(hub: hub, home: home, lookup: lookup) ? .key : .none
    }

    /// For a test: nothing of what this one hub said is kept. (Tests run at the same time, each with a hub of its own.)
    static func forget(hub: URL) { forgetSaid(name(hub: hub)) }
}

extension URLSession {
    /// **One call of the owner's Mac to its hub**: `data(for:)` with this Mac's key for that hub as the bearer
    /// (`OwnerMacKey.authorized`). A hub that holds no key of this Mac refuses a bearer on an owner route before it
    /// does anything (403, `key_not_expected`): the same request then goes once more with none, and that hub gets no
    /// key from then on. Every read and command of the hub's owner API goes through here. `home`, `lookup`: for a test.
    ///
    /// The sends that move a file (`hubBytes`, and `upload` and `download` with `OwnerMacKey.authorized`) only sign
    /// their request: they do not send again, because a file's body goes once. They follow reads that went through
    /// here in the same run, which is where the app learns that a hub expects no key.
    public func hubData(for request: URLRequest, home: URL? = OwnerMacKey.home,
                        lookup: @escaping @Sendable (String) -> String? = OwnerMacKey.systemLookup) async throws -> (Data, URLResponse) {
        let (wire, key) = OwnerMacKey.signing(request, home: home, lookup: lookup)
        let (data, response) = try await data(for: wire)
        // What the hub answered is kept by the request's own address: a hub's name stays that name here, also when
        // the request went to its number.
        var asked = request
        if let key { asked.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        guard OwnerMacKey.took(asked, ours: key != nil, answer: response, data, home: home, lookup: lookup) else {
            return (data, OwnerMacKey.asAsked(response, wire: wire, request: request))
        }
        let again = try await self.data(for: request)
        OwnerMacKey.took(request, ours: false, answer: again.1, again.0, home: home, lookup: lookup)
        return again
    }

    /// **A read of the hub that takes its answer as a stream** (`bytes(for:)`), with this Mac's key. The request goes
    /// to the hub's number when it carries the key (`OwnerMacKey.signing`), and the answer comes back under the
    /// address that the request was written with (`OwnerMacKey.asAsked`), so a caller's own check of the answer's
    /// address holds for a hub that is called by a name too.
    public func hubBytes(for request: URLRequest, home: URL? = OwnerMacKey.home,
                         lookup: @escaping @Sendable (String) -> String? = OwnerMacKey.systemLookup) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let wire = OwnerMacKey.signing(request, home: home, lookup: lookup).wire
        let (bytes, response) = try await bytes(for: wire)
        return (bytes, OwnerMacKey.asAsked(response, wire: wire, request: request))
    }
}

/// **How this Mac registers its key on a hub that runs** (`POST /ui/owner/key`), with no first-caller gap: the hub
/// writes a one-time value into a file of its own server, this Mac reads that file over the SSH connection that it has
/// to that server, and sends the value back with the SHA-256 of its new key. A guest behind this Mac has the Mac's
/// address and no SSH key, so it cannot read the file.
///
/// **The path comes from the hub, and this Mac can be root on the hub's server while the hub's own user is not.** So
/// nothing here reads the path with more rights than its owner has: the program on the server reads the file **as the
/// user that owns it**, and never as root. Whatever the hub's user names, links or swaps under that path, the read
/// gets what that user can read already. The path must also be a plain absolute path whose last part is the hub's own
/// name for the file, and only a value of the right shape, after the program's own mark, is ever sent back.
public enum OwnerMacKeyRegistration {
    /// The name that the hub gives the file (`hub.py` `OWNER_PROOF_FILE`).
    public static let proofFile = "owner-key.proof"
    /// What the program prints before the file's bytes, so that a line of `sudo`, of a login shell or of SSH itself
    /// in the output is not taken for the value and does not hide it.
    static let mark = "founderizer-proof:"

    /// The hub's answer to a call with no proof.
    public struct Asked: Decodable, Sendable {
        public let registered: Bool
        public let proof_file: String?
    }

    /// The hub's answer to a call with the proof.
    public struct Registered: Decodable, Sendable {
        public let registered: Bool
    }

    /// The path as this Mac may read it, or nil: absolute, of plain letters, with no `..` and no empty part, at most
    /// 512 letters, and its last part the hub's own name for the file.
    public static func path(_ said: String?) -> String? {
        guard let said, said.count <= 512,
              said.range(of: "^(/[A-Za-z0-9._-]+)+$", options: .regularExpression) != nil else { return nil }
        let parts = said.split(separator: "/").map(String.init)
        guard parts.last == proofFile, !parts.contains(".."), !parts.contains(".") else { return nil }
        return said
    }

    /// **The program that reads the file on the hub's server, as the file's own user.** It asks who owns the path
    /// (the link itself when the path is a link), by the user's number, and refuses root's, which is 0 whatever its
    /// name. It reads at most 64 bytes as that user: by itself when it runs as that user, else through `sudo -n -u`,
    /// which root may always do. So a path that changes between the question and the read gives nothing that its
    /// owner could not read. Then it prints its mark and what it read in one piece, so that a line which `sudo`
    /// writes while it reads stands before the mark and never between the mark and the value. Its last line is the
    /// server's own addresses (`addresses`), as `ip` or `ifconfig` gives them.
    public static func program(path: String) -> String {
        let file = InstallPlan.quote(path)
        return "f=\(file); u=$(stat -c %u -- \"$f\" 2>/dev/null || stat -f %u -- \"$f\" 2>/dev/null); "
            + "[ -n \"$u\" ] && [ \"$u\" != 0 ] || exit 1; "
            + "v=$(if [ \"$(id -u)\" = \"$u\" ]; then head -c 64 -- \"$f\"; else sudo -n -u \"#$u\" -- head -c 64 -- \"$f\"; fi 2>/dev/null); "
            + "printf '\(mark)%s\\n' \"$v\"; "
            + "a=$(PATH=\"$PATH:/usr/sbin:/sbin\"; { ip -o addr 2>/dev/null || ifconfig 2>/dev/null; } | tr '\\n' ' '); "
            + "printf '\(addressMark)%s\\n' \"$a\""
    }

    /// What the program prints before the server's own addresses.
    static let addressMark = "founderizer-addresses:"

    /// **The addresses of the server that the program ran on**, out of what it printed: each address that `ip -o addr`
    /// or `ifconfig` names after `inet` or `inet6`, in the line of the program's last address mark.
    ///
    /// The SSH connection is to a server whose host key this Mac knows, so these are the addresses of the hub's own
    /// server. A hub's **name** is something else: whoever answers its lookup chooses the number. So for a hub that is
    /// called by a name, the number must be one of these before this Mac sends the one-time value, or keeps a key,
    /// for it (`run`).
    static func addresses(_ output: String) -> [String] {
        guard let from = output.range(of: addressMark, options: .backwards) else { return [] }
        let line = String(output[from.upperBound...].prefix { !$0.isNewline })
        guard let pattern = try? NSRegularExpression(pattern: #"\binet6?\s+(?:addr:\s*)?([0-9A-Fa-f:.]+)"#) else { return [] }
        return pattern.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            Range(match.range(at: 1), in: line).map { String(line[$0]).lowercased() }
        }.filter { OwnerMacKey.isAddress($0) }
    }

    /// Whether two addresses are one, however each is written.
    static func same(_ one: String, _ other: String) -> Bool {
        func bytes(_ text: String) -> [UInt8]? {
            var four = in_addr(), six = in6_addr()
            if inet_pton(AF_INET, text, &four) == 1 { return withUnsafeBytes(of: &four) { Array($0) } }
            if inet_pton(AF_INET6, text, &six) == 1 { return withUnsafeBytes(of: &six) { Array($0) } }
            return nil
        }
        guard let a = bytes(one), let b = bytes(other) else { return false }
        return a == b
    }

    /// The one-time value out of what the program printed, or nil: what follows the program's last mark, to the end
    /// of that line, when it is 43 letters of base64url and nothing else.
    public static func value(_ output: String) -> String? {
        guard let from = output.range(of: mark, options: .backwards) else { return nil }
        // To the end of its line: a line can end in "\r\n", which is one character of a Swift string.
        let text = String(output[from.upperBound...].prefix { !$0.isNewline })
        return text.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil ? text : nil
    }

    #if os(macOS)
    /// The arguments of `ssh` for the program on the hub's server, with the installer's strict host key and no
    /// forwarding (`CentralVaultRemote.arguments`). `asRoot` false: as the user that this Mac logs in as, which is
    /// enough when that user owns the file, and all that a login with no `sudo` can do. True: as root, through
    /// `sudo -n` for a user that is not root.
    public static func arguments(target: InstallTarget, program: String, asRoot: Bool,
                                 ledger: SSHKeyLedger = .shared) -> [String] {
        CentralVaultRemote.call(target: target, program: program, runs: asRoot ? .root : .login)
            .arguments(SSHCall.key(for: target, ledger: ledger))
    }
    #endif

    /// One body to `POST /ui/owner/key` of `hub`: the answer's status and bytes. It carries no key, because the Mac
    /// that asks has none that the hub takes; the route knows the Mac by its address and by the file's value.
    public static func post(hub: URL, body: [String: String], session: URLSession? = nil) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: hub.appendingPathComponent("ui/owner/key"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let (data, response) = try await (session ?? URLSession(configuration: configuration)).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        return (http.statusCode, data)
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The hub did not take the first call, or named no path that this Mac may read.
        case noPath
        /// The SSH connection gave no value: no connection, no right to read, or another file.
        case noValue
        /// The hub refused the value.
        case refused
        /// No answer came to the call with the value. The hub can have registered the key: it waits, and the next
        /// read of the hub carries it.
        case noAnswer
        /// This Mac could not write its key. Before the call that tells the hub: nothing was sent. After the hub's
        /// yes: the key still waits in its file, and the next read of the hub carries it.
        case notKept
        /// The hub is called by a name, and the number that the name gives is no address of the fleet's private
        /// network that the server has which this Mac read the value from. The value is sent to nobody, and no key
        /// is made.
        case notThisServer
    }

    /// **The whole registration.** `post`: one JSON body to `POST /ui/owner/key` of the hub at the address that it
    /// is given, which gives the answer's status and bytes. `read`: the program run on the hub's server, which gives
    /// what it printed.
    ///
    /// The key is made here and kept as the key that waits **before** the call that tells the hub its SHA-256. So a
    /// write that fails sends nothing, and an answer that is lost loses nothing: the next call of this Mac carries the
    /// key that waits, and the hub's 2xx makes it the key (`OwnerMacKey.took`).
    ///
    /// **The key's place is found once, before anything is sent**: a hub that is called by a name is looked up one
    /// time, and the key that waits and the key that is kept go to the file of that one number. A name that has no
    /// number now registers nothing (`notKept`). The registration's own calls go to that number too, as each later
    /// call with the key does (`OwnerMacKey.signing`): so this Mac has a key only for a number at which its hub
    /// answers.
    ///
    /// **The number of a name must be an address of the server that the value was read from** (`addresses`), and one
    /// of the fleet's private network (`OwnerMacKey.isOfFleetNetwork`), or nothing more is sent (`notThisServer`).
    /// Whoever answers a name's lookup chooses its number: with that number taken on trust, another machine could
    /// get the one-time value, register a key of its own with it, and then get this Mac's key on each call. And a
    /// loopback address or the address of a bridge is on the hub's server and on this Mac too, where it is another
    /// machine's door. A hub that is written as a number is the owner's own word for where the hub is.
    ///
    /// **A registration that the hub refused keeps its key waiting.** The hub can hold that key all the same (the
    /// same call can have arrived a first time), and then the next read with it makes it the key; else it waits
    /// until the next registration writes over it.
    public static func run(hub: URL, home: URL? = OwnerMacKey.home,
                           lookup found: @Sendable (String) -> String? = OwnerMacKey.systemLookup,
                           post: @Sendable (URL, [String: String]) async throws -> (status: Int, data: Data),
                           read: @Sendable (String) async throws -> String) async throws {
        guard let host = hub.host?.lowercased(), !host.isEmpty else { throw Failure.notKept }
        var number: String?
        if !OwnerMacKey.isAddress(host) {
            guard let address = found(host).flatMap(OwnerMacKey.canonical) else { throw Failure.notKept }
            number = address
        }
        // A name: this one answer, to the end. A hub that is written as a number is never looked up.
        let lookup: @Sendable (String) -> String? = { [number] _ in number }
        guard let target = OwnerMacKey.numbered(hub, address: number ?? OwnerMacKey.canonical(host) ?? host) else {
            throw Failure.notKept
        }
        guard let first = try? await post(target, [:]), first.status == 200,
              let asked = try? JSONDecoder().decode(Asked.self, from: first.data), !asked.registered,
              let path = path(asked.proof_file) else { throw Failure.noPath }
        guard let output = try? await read(program(path: path)), let proof = value(output) else { throw Failure.noValue }
        if let number, !(OwnerMacKey.isOfFleetNetwork(number) && addresses(output).contains { same($0, number) }) {
            throw Failure.notThisServer
        }
        guard let key = try? OwnerMacKey.make(),
              (try? OwnerMacKey.keepWaiting(key, hub: hub, home: home, lookup: lookup)) != nil
        else { throw Failure.notKept }
        guard let second = try? await post(target, ["sha256": OwnerMacKey.digest(key), "proof": proof]) else { throw Failure.noAnswer }
        guard second.status == 200,
              (try? JSONDecoder().decode(Registered.self, from: second.data))?.registered == true else {
            throw Failure.refused
        }
        OwnerMacKey.promote(key, hub: hub, home: home, lookup: lookup)
        guard OwnerMacKey.read(hub: hub, home: home, lookup: lookup) == key else { throw Failure.notKept }
    }
}

/// **When this Mac registers its key, with no reads of its own** (`OwnerKeyModel` in the app asks it at each poll).
public enum OwnerKeyPlan {
    public enum Step: Equatable, Sendable {
        case nothing
        /// The hub takes this Mac's key: keep the SSH connection to the hub's server for a day on which the key is lost.
        case remember
        case register
    }

    /// How this Mac can reach the hub's own server.
    public enum Reach: Equatable, Sendable {
        case target(InstallTarget)
        /// The fleet's record of the hub's server is known and is no connection (`Record.none`), and this Mac keeps
        /// none.
        case none
        /// The fleet's record of the hub's server is not known (`Record.unknown`: a page did not answer, and no page
        /// that answered names the server), and this Mac keeps no connection.
        case unknown
    }

    /// - `held`: this Mac has a key for the hub, and the hub did not refuse that key as one it does not expect.
    /// - `known`: the place of this Mac's key for the hub is known (`OwnerMacKey.Holding.unknown` is the other case:
    ///   a hub's name with no number now). While it is not, nothing says whether this Mac has a key, and a new key
    ///   would have no place: nothing is registered, however the hub answers.
    /// - `refused`: the hub refused this Mac's last call for want of the right key.
    /// - `takesKeys`: the hub lists the feature. `fresh`: this Mac reads the hub now.
    /// - `tries`: the failed tries in a row. `registered`: when a registration last went through, or nil.
    ///
    /// A registration that went through is not made again for ten minutes, whatever the hub answers: each one is an
    /// SSH command on the hub's server and a new key for every program of this Mac, so a hub that keeps refusing
    /// gets one in ten minutes and not one at each poll.
    public static func step(held: Bool, known: Bool = true, refused: Bool, takesKeys: Bool, fresh: Bool, remembered: Bool,
                            tries: VaultTries?, registered: Double?, now: Double) -> Step {
        if held && !refused { return fresh && !remembered ? .remember : .nothing }
        guard known, refused || (fresh && takesKeys) else { return .nothing }
        if let tries, !tries.isDue(at: now) { return .nothing }
        if let registered, now - registered < VaultTries.wait { return .nothing }
        return .register
    }

    /// Whether System status says that this Mac could not register its key: at once when the fleet's record of the
    /// hub's server is known and is no connection (`Reach.none`), because another try changes nothing; else from the
    /// second failure in a row, so that one lost connection or one read that failed puts nothing on a page.
    public static func cannot(reach: Reach, failures: Int) -> Bool {
        reach == .none || failures >= 2
    }

    /// What the fleet has on record of how this Mac reaches the hub's own server.
    public enum Record: Equatable, Sendable {
        case reach(MachineReach)
        /// The pages that hold the record answered, and it is no whole connection.
        case none
        /// A page did not answer, and no page that answered names the server: nothing is known.
        case unknown
    }

    /// **The fleet's record of the connection to one server** (first written for the hub's own), out of the three
    /// pages that can hold it. All take it from the same entry of the fleet's file. `listed`: that server in the list
    /// of machines (`GET /ui/machines`), which names only a server that an agent runs on. `row`: that server's own
    /// row of the list of servers (`GET /ui/servers`, `ServerEntry.reach`; owner API 1.173), which needs no agent
    /// there, and which is nil when the row says nothing: from a hub before that version, and for a value that this
    /// app cannot use as a connection. `own`: the hub's record of its own server
    /// (`GET /ui/vault`, `HubClient.ownServer`), which needs no agent there either, names no other server, and which
    /// the vault's steps reach that server with.
    ///
    /// A hub from before the key was often installed by hand, on a server that runs no agent (15 November 2026: such
    /// a fleet got no key, because this Mac read the first page only). Then only the hub's own page had the
    /// connection. A server that joined and runs no agent was in none of the two pages of that day: only its row has
    /// its record.
    ///
    /// A page that names the server gives the fleet's record, whole or not, and no other page can say something else
    /// (`named`): the list first, then the server's row, then the hub's own page. A page that did not answer says
    /// nothing: when no page that answered names the server and one of them did not answer, nothing is known, and the
    /// block of System status waits for the second failure in a row (`cannot`). The row comes with the list of
    /// servers that named the server to its caller, so it is never a page that did not answer.
    public static func record(server: String, listed: MachineReach?, listRead: Bool, row: MachineReach? = nil,
                              own: VaultHub?, ownRead: Bool) -> Record {
        if let named = named(server: server, listed: listed, row: row, own: own) {
            return named.onRecord != nil ? .reach(named) : .none
        }
        return listRead && ownRead ? .none : .unknown
    }

    /// **What the first page that names the server says of it**, whole or not, in the order of `record`, which
    /// decides with it; nil when no page names the server. A page that shows the fleet's record of a server (the
    /// server's own page in Settings) reads this, so that it asks the owner for no connection that the fleet has.
    public static func named(server: String, listed: MachineReach?, row: MachineReach?, own: VaultHub?) -> MachineReach? {
        if let listed { return listed }
        if let row { return row }
        if let own, own.machine == server { return own.reach }
        return nil
    }

    /// **The reads, in their order, and what they give.** `row`: the server's row of the list of servers, which the
    /// caller has in hand. `machines`: the list of machines, or nil when it did not answer. `own`: the hub's record of
    /// its own server, nil when the hub names none; it throws when the page did not answer. The hub's own page is
    /// read only when neither the list nor the row names the server: a server that one of them names has its record
    /// there.
    public static func record(server: String, row: MachineReach? = nil, machines: @Sendable () async -> [MachineStatus]?,
                              own: @Sendable () async throws -> VaultHub?) async -> Record {
        let list = await machines()
        let listed = list.flatMap { MachineReach.of(server, in: $0) }
        var named: VaultHub?, ownRead = false
        if listed == nil, row == nil {
            do {
                named = try await own()
                ownRead = true
            } catch {}
        }
        return record(server: server, listed: listed, listRead: list != nil, row: row, own: named, ownRead: ownRead)
    }

    /// **What this Mac has when the fleet's record gives no connection**: the connection that it keeps from an earlier
    /// day, else `.none` when the record is known to have none, and `.unknown` when the record is not known.
    public static func reach(without record: Record, kept: InstallTarget?) -> Reach {
        if let kept { return .target(kept) }
        return record == .unknown ? .unknown : .none
    }
}
