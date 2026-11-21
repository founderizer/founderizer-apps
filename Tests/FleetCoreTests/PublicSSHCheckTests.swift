import Foundation
import Testing
@testable import FleetCore

/// The public SSH check of each server (the build spec of the app's SSH key, step 3): what the server says, which
/// places this Mac connects to, what it reads there, and when it checks again.
struct PublicSSHCheckTests {
    private static func output(addresses: String, ports: String = "22", root: String = "without-password") -> String {
        "\(PublicSSHCheck.addressesMark)\(addresses)\n\(PublicSSHCheck.portsMark)\(ports)\n\(PublicSSHCheck.rootMark)\(root)\n"
    }

    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var places: [PublicSSHCheck.Place] = []
        var all: [PublicSSHCheck.Place] { lock.withLock { places } }
        func add(_ place: PublicSSHCheck.Place) { lock.withLock { places.append(place) } }
    }

    /// **A private address is never checked**: the private network's, a provider's private network, loopback and
    /// link-local stay out, and only the server's own public addresses are asked, at each port of its sshd (or the
    /// round's own port where `sshd -T` gave none). Bug: this Mac connects to an address of a private network, where
    /// its open SSH port is the fleet's own route, and logs it as public SSH that is open.
    @Test func aPrivateAddressIsNeverChecked() async {
        let printed = Self.output(addresses: "203.0.113.5/32 10.0.0.5/24 100.84.1.2/32 192.168.1.4/24 172.16.0.3/16 "
                                  + "fd7a:115c:a1e0::5/128 fe80::1/64 2001:db8::5/64 203.0.113.5/32",
                                  ports: "22 2222 0 22")
        let reading = PublicSSHCheck.Reading.read("Welcome\n" + printed)
        #expect(reading == PublicSSHCheck.Reading(addresses: ["203.0.113.5", "2001:db8::5"], ports: [22, 2222],
                                                  rootLogin: "without-password"))
        #expect(reading?.places(fallback: 22).map(\.words)
                == ["203.0.113.5:22", "203.0.113.5:2222", "[2001:db8::5]:22", "[2001:db8::5]:2222"])
        #expect(PublicSSHCheck.Reading.read(Self.output(addresses: "203.0.113.5/32", ports: ""))?.places(fallback: 2200)
                    .map(\.words) == ["203.0.113.5:2200"])
        #expect(PublicSSHCheck.Reading.read("Permission denied\n") == nil)    // the program did not run

        let asked = Asked()
        let target = InstallTarget(host: "100.84.1.2", user: "root", port: 22)
        let onlyPrivate = await PublicSSHCheck.check(connection: { target }, run: { _, _ in
            Self.output(addresses: "10.0.0.5/24 100.84.1.2/32 fd7a:115c:a1e0::5/128")
        }, greeting: { asked.add($0); return .answered("SSH-2.0-OpenSSH_9.6") })
        #expect(asked.all.isEmpty && onlyPrivate == PublicSSHCheck.Outcome(
            line: "no public address on its interfaces; root login: without-password", read: true))
    }

    /// **A closed port is not open**: only an SSH greeting is `open`; a port that refused, that nothing answered, or
    /// where another program answered is `closed`, and the server that the round could not read is said so. Bug: a
    /// refused or silent port is logged as open, or a port of another program reads as public SSH.
    @Test func aClosedPortIsNotOpen() async {
        #expect(PublicSSHCheck.state(greeting: "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13") == .open)
        #expect(PublicSSHCheck.state(greeting: nil) == .closed)
        #expect(PublicSSHCheck.state(greeting: "HTTP/1.1 400 Bad Request") == .closed)
        #expect(PublicSSHCheck.state(greeting: "") == .closed)
        let target = InstallTarget(host: "100.84.1.2", user: "root", port: 22)
        let outcome = await PublicSSHCheck.check(connection: { target }, run: { _, _ in
            Self.output(addresses: "203.0.113.5/32 2001:db8::5/64", root: "no")
        }, greeting: { $0.address == "203.0.113.5" ? .closed : .answered("SSH-2.0-OpenSSH_9.6") })
        #expect(outcome == PublicSSHCheck.Outcome(line: "203.0.113.5:22 closed, [2001:db8::5]:22 open; root login: no",
                                                  read: true))
        struct NoConnection: Error {}
        let none = await PublicSSHCheck.check(connection: { throw NoConnection() }, run: { _, _ in "" },
                                              greeting: { _ in .answered("SSH-2.0-OpenSSH_9.6") })
        #expect(none == PublicSSHCheck.Outcome(line: "not read: no connection", read: false))
    }

    /// **No route from this Mac is no reading** (Fable's check of 21 November 2026): a connection that waits for a
    /// route (an IPv6 address from a network with IPv4 only, or no network) is "not reached from this Mac", a refused
    /// connection is still `closed`, and the check read the server, so the next is due a day later. Bugs: a Mac with no
    /// IPv6 logs each server's IPv6 SSH as closed, so the log says that a port is shut that nobody looked at; or that
    /// place makes the check one that did not read the server, and a root SSH run, its connections and a log line come
    /// each hour for ever.
    @Test func aPlaceWithNoRouteFromThisMacIsNotReachedAndTheCheckIsRead() async {
        #expect(PublicSSHCheck.contact(waiting: .posix(.ENETUNREACH)) == .unreached)
        #expect(PublicSSHCheck.contact(waiting: .posix(.EHOSTUNREACH)) == .unreached)
        #expect(PublicSSHCheck.contact(waiting: .posix(.ENETDOWN)) == .unreached)
        #expect(PublicSSHCheck.contact(waiting: .posix(.ECONNREFUSED)) == .closed)
        let target = InstallTarget(host: "100.84.1.2", user: "root", port: 22)
        let outcome = await PublicSSHCheck.check(connection: { target }, run: { _, _ in
            Self.output(addresses: "203.0.113.5/32 2001:db8::5/64")
        }, greeting: { $0.address == "2001:db8::5" ? .unreached : .answered("SSH-2.0-OpenSSH_9.6") })
        #expect(outcome == PublicSSHCheck.Outcome(
            line: "203.0.113.5:22 open, [2001:db8::5]:22 not reached from this Mac; root login: without-password", read: true))
    }

    /// **Once a day**, and an hour after a check that could not read the server. Bugs: the check runs in each round of
    /// five minutes, a connection to each public port of each server every time; a check that failed once is never
    /// due again; a clock that went back holds it for good.
    @Test func theCheckIsDueOnceADay() {
        let now = 1_794_000_000.0
        #expect(PublicSSHCheck.due(next: nil, now: now))
        let read = PublicSSHCheck.next(read: true, now: now), unread = PublicSSHCheck.next(read: false, now: now)
        #expect(read == now + 86_400 && unread == now + 3_600)
        #expect(!PublicSSHCheck.due(next: read, now: now + 300) && !PublicSSHCheck.due(next: read, now: now + 86_399))
        #expect(PublicSSHCheck.due(next: read, now: now + 86_400) && PublicSSHCheck.due(next: unread, now: now + 3_600))
        #expect(PublicSSHCheck.due(next: read, now: now - 3_600))         // the clock went back an hour and more
    }
}
