import Foundation
import Testing
@testable import FleetCore

/// **The kinds of `setup_diagnosis`**: a failed read of the hub, Tailscale and the hub's device from fixture JSON, the
/// one flight of the Tailscale read, and where the window stands. No test runs the real `tailscale` program.
struct ReachFactsTests {
    // ------------------------------------------------------------ a failed read

    @Test func eachErrorHasItsKind() {
        struct Elsewhere: Error {}
        let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "example"))
        let table: [(Error?, ReachFacts.ReadKind)] = [
            (nil, .none),
            (HubError.invalidAddress, .invalidAddress),
            (HubError.invalidResponse, .unreadable),
            (HubError.unavailable, .noConnection),
            (HubError.refusal(403, "owner only"), .refusedThisMac),
            (HubError.refusal(404, "x"), .notAHub),
            (HubError.refusal(500, "x"), .hubError),
            (HubError.refusal(503, "x"), .hubError),
            (HubError.refusal(400, "x"), .refused),
            (HubError.refusal(409, "x"), .refused),
            (decoding, .unreadable),
            (URLError(.appTransportSecurityRequiresSecureConnection), .blockedByApp),
            (URLError(.cannotFindHost), .hostNotFound),
            (URLError(.dnsLookupFailed), .hostNotFound),
            (URLError(.cannotConnectToHost), .noConnection),
            (URLError(.networkConnectionLost), .noConnection),
            (URLError(.notConnectedToInternet), .noNetwork),
            (URLError(.timedOut), .timedOut),
            (URLError(.secureConnectionFailed), .notSecure),
            (URLError(.serverCertificateUntrusted), .notSecure),
            (URLError(.cancelled), .other),
            (URLError(.badServerResponse), .other),
            (Elsewhere(), .other),
        ]
        for (error, kind) in table {
            #expect(ReachFacts.readKind(error) == kind, "\(String(describing: error))")
        }
        #expect(ReachFacts.ReadKind.allCases.count == 14)
    }

    /// **Each error that has its own line in `HubReach.words` has a kind that is not `other`**: the line is the
    /// owner's, the kind the agent's, and the two say the same thing.
    @Test func eachOwnLineOfHubReachHasAKindOfItsOwn() {
        let otherLine = HubReach.words(URLError(.badServerResponse), hub: nil)
        let errors: [Error] = [HubError.invalidAddress, HubError.invalidResponse, HubError.unavailable,
                               HubError.refusal(403, "x"), HubError.refusal(404, "x"), HubError.refusal(503, "x"),
                               URLError(.appTransportSecurityRequiresSecureConnection), URLError(.cannotFindHost),
                               URLError(.dnsLookupFailed), URLError(.cannotConnectToHost),
                               URLError(.networkConnectionLost), URLError(.notConnectedToInternet),
                               URLError(.timedOut), URLError(.secureConnectionFailed),
                               URLError(.serverCertificateUntrusted)]
        for error in errors {
            #expect(HubReach.words(error, hub: nil) != otherLine)
            #expect(ReachFacts.readKind(error) != .other, "\(error)")
        }
    }

    // ------------------------------------------------------------ Tailscale and the hub's device

    #if os(macOS)
    static func status(_ state: String = "Running", own: [String] = ["100.101.100.180"],
                       online: Bool = true) -> String {
        let addresses = "[" + own.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        return """
        {"BackendState": "\(state)",
         "Self": {"DNSName": "example-mac.tail1234.ts.net.", "TailscaleIPs": \(addresses), "Online": \(online)},
         "Peer": {
           "a": {"DNSName": "worker-1.tail1234.ts.net.", "TailscaleIPs": ["100.96.100.130"], "Online": false},
           "b": {"DNSName": "worker-2.tail1234.ts.net.", "TailscaleIPs": ["fd7a:115c:a1e0::2", "100.96.10.20"], "Online": true},
           "c": {"DNSName": "", "TailscaleIPs": ["100.64.0.9"], "Online": true}
         }}
        """
    }

    /// **A hub whose node has no MagicDNS name is still in the network**, and a Mac whose own node is not online
    /// reads no device: its peers' marks are old.
    @Test func aPeerWithNoNameCountsAndAMacThatIsNotOnlineReadsNoDevice() {
        #expect(ReachFacts.network(Self.read(Self.status()), hubHost: "100.64.0.9") == (.connected, .online))
        let away = Self.read(Self.status(online: false))
        #expect(ReachFacts.network(away, hubHost: "100.96.10.20") == (.connected, .notRead))
        #expect(ReachFacts.network(away, hubHost: "100.96.100.130") == (.connected, .notRead))
    }

    /// **A read is measured by the clock that ends it** (`Date`, as `LocalShell`): a read killed at its limit is
    /// `ended`, also when its kill gave a status of its own; one that failed early is an exit.
    @Test func aKilledReadIsEndedByTheClockThatEndsIt() async {
        let killed = LocalShell.Answer(status: 15, output: "")
        #expect(ReachFacts.ended(killed, took: 5.2, limit: 5) == .init(end: .ended))
        #expect(ReachFacts.ended(killed, took: 1, limit: 5) == .init(end: .exited(15)))
        #expect(ReachFacts.ended(LocalShell.Answer(status: 0, output: "{}"), took: 9, limit: 5)
                == .init(end: .exited(0), output: "{}"))
        // A test's own clock: the read takes 6 seconds of it.
        final class Moments: @unchecked Sendable {
            var dates = [Date(timeIntervalSince1970: 1000), Date(timeIntervalSince1970: 1006)]
            func next() -> Date { dates.removeFirst() }
        }
        let moments = Moments()
        let read = await ReachFacts.readTailscale(limit: 5, command: "/example/tailscale", now: { moments.next() },
                                                  run: { _, arguments, _ in
                                                      #expect(arguments == ["TAILSCALE_BE_CLI=1", "/example/tailscale",
                                                                            "status", "--json"])
                                                      return LocalShell.Answer(status: 15, output: "")
                                                  })
        #expect(read.end == .ended)
        #expect(await ReachFacts.readTailscale(command: nil).end == .noCommand)
    }

    static func read(_ output: String, status: Int32 = 0) -> ReachFacts.TailscaleRead {
        ReachFacts.TailscaleRead(end: .exited(status), output: output)
    }

    @Test func eachTailscaleStateFromItsStatus() {
        let host = "100.96.10.20"
        #expect(ReachFacts.network(.init(end: .noCommand), hubHost: host) == (.notInstalled, .notRead))
        #expect(ReachFacts.network(Self.read(Self.status()), hubHost: host) == (.connected, .online))
        #expect(ReachFacts.network(Self.read(Self.status(own: [])), hubHost: host) == (.notConnected, .notRead))
        #expect(ReachFacts.network(Self.read(Self.status("Stopped")), hubHost: host) == (.notConnected, .notRead))
        #expect(ReachFacts.network(Self.read(Self.status("NeedsLogin")), hubHost: host) == (.notSignedIn, .notRead))
        #expect(ReachFacts.network(Self.read(Self.status("NoState")), hubHost: host) == (.notSignedIn, .notRead))
    }

    /// **A read that failed is never `not_signed_in`**: a read ended at its limit, one that could not start and one
    /// with no status are `not_read`; another failed exit is `not_running`.
    @Test func aReadThatFailedIsNeverNotSignedIn() {
        let host = "100.96.10.20"
        #expect(ReachFacts.network(.init(end: .ended, output: Self.status()), hubHost: host) == (.notRead, .notRead))
        #expect(ReachFacts.network(.init(end: .cannotStart), hubHost: host) == (.notRead, .notRead))
        #expect(ReachFacts.network(Self.read("failed to connect to local Tailscale service; is Tailscale running?",
                                             status: 1), hubHost: host) == (.notRunning, .notRead))
        #expect(ReachFacts.network(Self.read(""), hubHost: host) == (.notRead, .notRead))
        #expect(ReachFacts.network(Self.read("{\"Version\": \"1.0\"}"), hubHost: host) == (.notRead, .notRead))
        #expect(ReachFacts.network(Self.read("{ not json"), hubHost: host) == (.notRead, .notRead))
    }

    @Test func aWarningLineBeforeTheStatusIsSkipped() {
        let output = "Warning: client version \"1.0\" != tailscaled server version \"1.2\"\n" + Self.status()
        #expect(ReachFacts.network(Self.read(output), hubHost: "100.96.10.20") == (.connected, .online))
    }

    @Test func eachDeviceOutcome() {
        let status = Self.read(Self.status())
        #expect(ReachFacts.network(status, hubHost: "100.96.10.20").hubDevice == .online)
        #expect(ReachFacts.network(status, hubHost: "100.96.100.130").hubDevice == .offline)
        #expect(ReachFacts.network(status, hubHost: "100.64.1.1").hubDevice == .notInNetwork)
        #expect(ReachFacts.network(status, hubHost: "100.101.100.180").hubDevice == .thisMac)
        #expect(ReachFacts.network(status, hubHost: "hub.example.com").hubDevice == .notKnown)
        #expect(ReachFacts.network(status, hubHost: "worker-2").hubDevice == .notKnown)
        #expect(ReachFacts.network(status, hubHost: "192.0.2.10").hubDevice == .notKnown)
        #expect(ReachFacts.network(status, hubHost: nil).hubDevice == .notKnown)
    }
    #endif

    // ------------------------------------------------------------ one flight

    /// A clock and a count that the test moves.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 100
        private var count = 0
        var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
        var runs: Int { lock.lock(); defer { lock.unlock() }; return count }
        func move(_ by: TimeInterval) { lock.lock(); time += by; lock.unlock() }
        func ran() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }

    /// **One run and one parse for two callers of one host**: the run gives the finished facts.
    @Test func twoCallersShareOneRunAndOneParse() async {
        let clock = Clock()
        let flight = KeptFlight<String, Int>(keep: 10, now: { clock.now }) { _ in
            let run = clock.ran()
            try? await Task.sleep(for: .milliseconds(200))
            return run
        }
        async let first = flight.value(for: "100.96.10.20")
        async let second = flight.value(for: "100.96.10.20")
        let both = await [first, second]
        #expect(both == [1, 1])
        #expect(clock.runs == 1)
        #expect(await flight.runs == 1)
        // Another host runs again.
        #expect(await flight.value(for: "100.96.100.130") == 2)
        #expect(clock.runs == 2)
    }

    @Test func aResultIsKeptTenSecondsAndAFailedOneToo() async {
        let clock = Clock()
        // A failed read is a value like any other: kept as long.
        let flight = KeptFlight<String, String>(keep: 10, now: { clock.now }) { _ in
            clock.ran() == 1 ? "failed" : "read"
        }
        #expect(await flight.value(for: "hub") == "failed")
        clock.move(9.9)
        #expect(await flight.value(for: "hub") == "failed")
        #expect(clock.runs == 1)
        clock.move(0.1)
        #expect(await flight.value(for: "hub") == "read")
        #expect(clock.runs == 2)
    }

    /// A caller whose task is cancelled gets nil and starts no run.
    @Test func aCancelledCallerStartsNoRun() async {
        let clock = Clock()
        let flight = KeptFlight<String, Int>(keep: 10, now: { clock.now }) { _ in clock.ran() }
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await flight.value(for: "hub")
        }
        #expect(await call.value == nil)
        #expect(clock.runs == 0)
    }

    // ------------------------------------------------------------ where the window stands

    @Test func theWindowAndTheAgentsSetup() {
        let setup = ReachFacts.AgentSetup(manager: true, placed: false, serverJoined: false)
        func window(_ firstRun: Bool, settings: Bool = false, reading: Bool = true,
                    _ page: ReachFacts.Page) -> (ReachFacts.Window, ReachFacts.AgentSetup?) {
            let found = ReachFacts.window(firstRun: firstRun, settings: settings, hasReading: reading, page: page)
            return (found.window, found.agentSetup)
        }
        #expect(window(true, .agentSetup(setup)) == (.firstRun, nil))
        #expect(window(true, .other) == (.firstRun, nil))
        #expect(window(false, .addServer) == (.addServer, nil))
        #expect(window(false, .addAgent) == (.addAgent, nil))
        #expect(window(false, .other) == (.fleet, nil))
        // With Settings open the app shows Settings, not the first run: Add server is a page of Settings.
        #expect(window(true, settings: true, .other) == (.fleet, nil))
        #expect(window(true, settings: true, .addServer) == (.addServer, nil))
        // Add agent with no reading: the app shows its waiting page.
        #expect(window(false, reading: false, .addAgent) == (.fleet, nil))
        let shown = window(false, .agentSetup(setup))
        #expect(shown.0 == .agentSetup && shown.1 == setup)
        // **The welcome page in front of a setup that never finished is the first run's page**, also while the
        // window is closed and no page of the first run says that it shows: never the agent's setup behind it.
        let covered = ReachFacts.window(firstRun: false, settings: false, hasReading: true, page: .agentSetup(setup),
                                        welcomeCovers: true)
        #expect(covered.window == .firstRun && covered.agentSetup == nil)
        let open = ReachFacts.window(firstRun: true, settings: false, hasReading: true, page: .agentSetup(setup),
                                     welcomeCovers: true)
        #expect(open.window == .firstRun && open.agentSetup == nil)
        #expect(ReachFacts.Window.allCases.map(\.rawValue) == ["first_run", "agent_setup", "add_server", "add_agent",
                                                               "fleet"])
    }
}
