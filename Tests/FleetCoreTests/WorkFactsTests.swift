import Foundation
import Testing
@testable import FleetCore

/// **The app's own work as kinds** (`setup_diagnosis`, step 2): a build at a provider, with its stop kept after the
/// page cleared it, an install with its state, kind, step and the kind of its stop, and what the kept records say of
/// the last install and of servers that never joined. No test makes a server, runs an install or writes a record's
/// file.
struct WorkFactsTests {
    // ------------------------------------------------------------ a build at a provider

    static let start = Date(timeIntervalSince1970: 1000)

    /// The model's calls, one after the other, from no value: the facts after each.
    static func told(_ calls: [(ReachFacts.BuildStage, ReachFacts.BuildStage?)], from old: ReachFacts.BuildFacts? = nil,
                     use: CloudServerUse = .hub) -> [ReachFacts.BuildFacts] {
        var now = old
        var all: [ReachFacts.BuildFacts] = []
        for (index, call) in calls.enumerated() {
            let next = ReachFacts.build(after: now, stage: call.0, stopped: call.1, use: use, provider: .hetzner,
                                        now: start.addingTimeInterval(Double(index)))
            all.append(next)
            now = next
        }
        return all
    }

    /// **A stop**, in the order of the model's calls: `stopped` first, while `stage` is still the build's, then `stage`.
    @Test func aStopIsKeptWithItsStage() {
        let facts = Self.told([(.choosing, nil), (.making, nil), (.joining, nil), (.joining, .joining), (.token, .joining)])
        #expect(facts.map(\.stoppedAt) == [nil, nil, nil, .joining, .joining])
        #expect(facts.map(\.stopShows) == [false, false, false, true, true])
        #expect(facts.last?.stage == .token)
        // The provider refused the token: the stop comes while the stage is still choosing.
        let token = Self.told([(.choosing, nil), (.choosing, .token), (.token, .token)])
        #expect(token.last?.stoppedAt == .token && token.last?.stopShows == true)
    }

    /// **A cancel after a stop keeps the stop**, and says that the page no longer shows it: Add server's `opened()`
    /// cancels a build that stopped.
    @Test func aCancelAfterAStopKeepsIt() {
        let stopped = Self.told([(.making, nil), (.making, .making), (.token, .making)]).last
        let cancelled = Self.told([(.token, nil), (.token, nil)], from: stopped)
        #expect(cancelled.map(\.stoppedAt) == [.making, .making])
        #expect(cancelled.map(\.stopShows) == [false, false])
        // A press that made nothing (the stop while the list shows), then Back: kept as well.
        let list = Self.told([(.choosing, nil), (.choosing, .choosing), (.choosing, nil), (.token, nil)])
        #expect(list.map(\.stoppedAt) == [nil, .choosing, .choosing, .choosing])
        #expect(list.last?.stopShows == false)
    }

    /// **A new try clears the kept stop**: the stage leaves `token`, or the list's press makes the server.
    @Test func aNewTryClearsIt() {
        let stopped = Self.told([(.making, nil), (.joining, nil), (.joining, .joining), (.token, .joining)]).last
        let again = Self.told([(.token, nil), (.choosing, nil)], from: stopped)
        #expect(again.map(\.stoppedAt) == [.joining, nil])
        #expect(again.last?.stopShows == false && again.last?.stage == .choosing)
        let pressed = Self.told([(.choosing, nil), (.choosing, .choosing), (.choosing, nil), (.making, nil)])
        #expect(pressed.last?.stoppedAt == nil && pressed.last?.stage == .making)
    }

    /// **A build that ends well** leaves no stop.
    @Test func aBuildThatEndsWellLeavesNoStop() {
        let facts = Self.told([(.choosing, nil), (.making, nil), (.joining, nil), (.token, nil)])
        #expect(facts.map(\.stage) == [.choosing, .making, .joining, .token])
        #expect(facts.allSatisfy { $0.stoppedAt == nil && !$0.stopShows })
    }

    /// **The seconds count from the stage's start**: a call that changes no stage keeps its start, and at `token`
    /// there are none.
    @Test func theSecondsCountFromTheStagesStart() {
        let facts = Self.told([(.making, nil), (.making, nil), (.making, nil), (.joining, nil)])
        #expect(facts.map(\.since) == [Self.start, Self.start, Self.start, Self.start.addingTimeInterval(3)])
        #expect(ReachFacts.seconds(in: facts[2], now: Self.start.addingTimeInterval(42)) == 42)
        #expect(ReachFacts.seconds(in: facts[2], now: Self.start.addingTimeInterval(-5)) == 0)
        let token = Self.told([(.token, nil)]).last
        #expect(ReachFacts.seconds(in: token, now: Self.start.addingTimeInterval(9)) == nil)
        #expect(ReachFacts.seconds(in: nil as ReachFacts.BuildFacts?, now: Self.start) == nil)
        // The use and the provider pass as they are.
        let agent = Self.told([(.choosing, nil)], use: .agent).last
        #expect(agent?.use == .agent && agent?.provider == .hetzner)
    }

    /// **More than one model writes one value** (each first-run view has its own model): an idle model does not
    /// replace another model's build that runs, and a model always replaces what it wrote itself.
    @Test func anIdleModelDoesNotReplaceABuildThatRuns() {
        let other = Self.told([(.choosing, nil), (.making, nil)]).last!
        let idle = Self.told([(.token, nil)]).last!
        #expect(ReachFacts.kept(idle, over: other, mine: nil) == other)
        let joining = Self.told([(.joining, nil)], from: other).last!
        #expect(ReachFacts.kept(idle, over: joining, mine: idle) == joining)
        // The same model's build that ends well leaves token.
        let ended = Self.told([(.token, nil)], from: joining).last!
        #expect(ReachFacts.kept(ended, over: joining, mine: joining) == ended)
        // A stop that this model holds, at token and at choosing, always replaces: its page shows it now.
        let stop = Self.told([(.choosing, .token), (.token, .token)]).last!
        #expect(stop.stage == .token && stop.stopShows)
        #expect(ReachFacts.kept(stop, over: other, mine: nil) == stop)
        let stopOnList = Self.told([(.choosing, .choosing)]).last!
        #expect(ReachFacts.kept(stopOnList, over: other, mine: nil) == stopOnList)
        // A model that only shows its list does not replace another model's build that runs; one that builds does.
        let listing = Self.told([(.choosing, nil)]).last!
        #expect(ReachFacts.kept(listing, over: other, mine: nil) == other)
        let building = Self.told([(.choosing, nil), (.making, nil)]).last!
        #expect(ReachFacts.kept(building, over: other, mine: nil) == building)
        // Another model's kept stop stays while this one is idle, and goes when this one starts a try.
        let keptStop = Self.told([(.joining, nil), (.joining, .joining), (.token, .joining), (.token, nil)]).last!
        #expect(keptStop.stoppedAt == .joining && !keptStop.stopShows)
        #expect(ReachFacts.kept(idle, over: keptStop, mine: nil) == keptStop)
        #expect(ReachFacts.kept(listing, over: keptStop, mine: nil) == listing)
        #expect(ReachFacts.kept(idle, over: keptStop, mine: keptStop) == idle)
        // A stored value that does not run and holds no stop is replaced by an idle model.
        #expect(ReachFacts.kept(idle, over: listing, mine: nil) == idle)
        #expect(ReachFacts.kept(idle, over: nil, mine: nil) == idle)
    }

    #if os(macOS)
    // ------------------------------------------------------------ an install

    /// Each case of a type, read from the app's source between its opening line and its first closing brace.
    static func cases(in path: String, after opening: String) throws -> [String] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(path)
        let source = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(source.range(of: opening))
        let end = try #require(source.range(of: "}", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        let line = try NSRegularExpression(pattern: #"^\s*case ([a-z, ]+)$"#, options: .anchorsMatchLines)
        return line.matches(in: body, range: NSRange(body.startIndex..., in: body))
            .flatMap { (body as NSString).substring(with: $0.range(at: 1)).components(separatedBy: ", ") }
    }

    /// **The way `mac` is the app's own**: the cases of `MachineInstallModel.Way`, read from the app's source.
    @Test func theWayMacIsTheModelsCase() throws {
        let ways = try Self.cases(in: "Sources/Founderizer/MachineInstallView.swift",
                                  after: "enum Way: String, CaseIterable, Identifiable, Hashable {")
        #expect(ways == ["linux", "mac", "line"])
    }

    /// **A Mac's install that ended with no checklist is done**, as the model means it: its task ended with no stop.
    @Test func anEndWithNoChecklistIsDone() throws {
        let mac = try #require(ReachFacts.install(Self.link(way: "mac", ended: true, steps: [("order", .running)])))
        #expect(mac.state == .done && mac.kind == .mac && mac.step == .none)
    }

    /// **Seconds only while a step runs**: an install that waits for its first step gives none.
    @Test func noSecondsBeforeTheFirstStep() throws {
        let waits = try #require(ReachFacts.install(Self.link(running: true, planned: Self.joinIDs)))
        #expect(waits.state == .running && waits.step == .none && waits.since == nil)
        #expect(ReachFacts.seconds(in: waits, now: Self.start.addingTimeInterval(1200)) == nil)
    }

    /// **The install's plain facts hold no words of a stop**: the fields of `InstallLink`, read from its source, are
    /// these, and the model's line that makes them gives the fixed kind and none of the model's words. A field for
    /// words that comes back fails here.
    @Test func noWordsOfAStopReachTheFacts() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let facts = try String(contentsOf: file.appendingPathComponent("Sources/FleetCore/WorkFacts.swift"), encoding: .utf8)
        let start = try #require(facts.range(of: "public struct InstallLink: Equatable, Sendable {"))
        let end = try #require(facts.range(of: "public init(way:", range: start.upperBound..<facts.endIndex))
        let field = try NSRegularExpression(pattern: #"^        public var ([A-Za-z]+): ([^\n]+)$"#,
                                            options: .anchorsMatchLines)
        let body = String(facts[start.upperBound..<end.lowerBound])
        let fields = field.matches(in: body, range: NSRange(body.startIndex..., in: body)).map {
            (body as NSString).substring(with: $0.range(at: 1)) + ": " + (body as NSString).substring(with: $0.range(at: 2))
        }
        #expect(fields == ["way: String", "running: Bool", "failed: Bool", "ended: Bool", "job: String?",
                           "steps: [Step]", "planned: [String]", "runningStep: String?", "since: Date",
                           "stop: InstallRecord.Stop?", "waitsForNetwork: Bool"])
        // The model's own line: the kind, and neither of its two texts of a stop.
        let model = try String(contentsOf: file.appendingPathComponent("Sources/Founderizer/MachineInstallView.swift"),
                               encoding: .utf8)
        let from = try #require(model.range(of: "var linkFacts: ReachFacts.InstallLink {"))
        let to = try #require(model.range(of: "\n    }\n", range: from.upperBound..<model.endIndex))
        let line = String(model[from.upperBound..<to.lowerBound])
        #expect(line.contains("stop: stop, waitsForNetwork: needsNetworkKey"))
        #expect(!line.contains("failureDetail") && !line.contains("failure,") && !line.contains("networkFailure"))
    }

    static func link(way: String = "linux", running: Bool = false, failed: Bool = false, ended: Bool = false,
                     job: InstallJob? = nil, steps: [(String, InstallProgress.State)] = [], planned: [String] = [],
                     runningStep: String? = nil, stop: InstallRecord.Stop? = nil,
                     waitsForNetwork: Bool = false) -> ReachFacts.InstallLink {
        ReachFacts.InstallLink(way: way, running: running, failed: failed, ended: ended, job: job?.rawValue,
                               steps: steps.map { InstallProgress(step: $0.0, title: "Example", says: "", state: $0.1) },
                               planned: planned, runningStep: runningStep, since: start, stop: stop,
                               waitsForNetwork: waitsForNetwork)
    }

    static let joinIDs = ["read", "network", "join", "verify"]
    static let hubIDs = ["read", "network", "code", "plan", "start", "wait_claim", "claim", "wait_ready", "verify"]

    @Test func eachStateOfAnInstall() throws {
        #expect(ReachFacts.install(Self.link()) == nil)
        let running = try #require(ReachFacts.install(Self.link(running: true, steps: [("read", .done),
                                                                                      ("network", .running)],
                                                                planned: Self.joinIDs, runningStep: "network")))
        #expect(running == .init(state: .running, kind: .server, step: .network, stop: nil, stepsDone: 1,
                                 stepsPlanned: 4, since: Self.start))
        #expect(ReachFacts.seconds(in: running, now: Self.start.addingTimeInterval(17)) == 17)
        let stopped = try #require(ReachFacts.install(Self.link(failed: true, steps: [("read", .done), ("network", .done),
                                                                                     ("code", .failed)],
                                                                planned: Self.hubIDs)))
        #expect(stopped.state == .stopped && stopped.kind == .hub && stopped.step == .code && stopped.since == nil)
        #expect(stopped.stepsDone == 2 && stopped.stepsPlanned == 9)
        #expect(ReachFacts.seconds(in: stopped, now: Self.start) == nil)
        let done = try #require(ReachFacts.install(Self.link(ended: true, steps: Self.joinIDs.map { ($0, .done) },
                                                             planned: Self.joinIDs)))
        #expect(done.state == .done && done.step == .none && done.stop == nil && done.stepsDone == 4)
        // A page ended it while it ran: its steps stay, and it neither runs, nor stopped, nor ended.
        let ended = try #require(ReachFacts.install(Self.link(steps: [("read", .done), ("network", .running)],
                                                              planned: Self.joinIDs)))
        #expect(ended.state == .none && ended.step == .network && ended.stop == nil)
        // A stop before any step (the hub gave no line): no step.
        let early = try #require(ReachFacts.install(Self.link(failed: true)))
        #expect(early.state == .stopped && early.step == .none && early.kind == .server)
        // **The job says the kind before the plan**: a hub's install that stopped before its plan is the hub's, a
        // join is a server's, and a Mac's way stays a Mac's whatever the job.
        #expect(ReachFacts.install(Self.link(failed: true, job: .hub))?.kind == .hub)
        #expect(ReachFacts.install(Self.link(failed: true, job: .join))?.kind == .server)
        #expect(ReachFacts.install(Self.link(way: "mac", failed: true, job: .join))?.kind == .mac)
        #expect(ReachFacts.install(Self.link(failed: true, job: .join, planned: Self.joinIDs))?.kind == .server)
        #expect(ReachFacts.install(Self.link(running: true, job: .hub, planned: Self.hubIDs))?.kind == .hub)
    }

    /// **Each id of the two plans is its own step**; an unknown id is `other`, and the words `none` and `other` as ids
    /// are `other` too.
    @Test func eachPlanIDIsItsStep() {
        let target = InstallTarget(host: "100.64.0.9")
        let hub = InstallPlan.hub(target: target, source: "https://example.com/founderizer.git", authKey: nil)
        let join = InstallPlan.join(target: target, line: "curl -fsSL https://example.com/join | sh", code: "example",
                                    authKey: nil)
        #expect(hub.steps.map(\.id) == Self.hubIDs && join.steps.map(\.id) == Self.joinIDs)
        for id in hub.steps.map(\.id) + join.steps.map(\.id) {
            #expect(ReachFacts.installStep(id).rawValue == id)
        }
        #expect(ReachFacts.longestPlan == max(hub.steps.count, join.steps.count))
        #expect(ReachFacts.installStep("order") == .order)
        #expect(ReachFacts.installStep("Install Founderizer") == .other)
        #expect(ReachFacts.installStep("none") == .other && ReachFacts.installStep("other") == .other)
        #expect(ReachFacts.installStep(nil) == .none)
    }

    /// **A Mac's install comes from that Mac**: its ids pass the list or are `other`, and its counts are capped. The
    /// kind of its stop is the app's own, as the model gives it.
    @Test func aMacsInstallPassesOnlyTheFixedLists() throws {
        let many = (0..<20).map { ("step-\($0)", InstallProgress.State.done) } + [("install_agent", .failed)]
        let mac = try #require(ReachFacts.install(Self.link(way: "mac", failed: true, steps: many, stop: .macRefused)))
        #expect(mac.kind == .mac && mac.step == .other && mac.stop == .macRefused && !mac.waitsForNetwork)
        #expect(mac.stepsDone == ReachFacts.longestPlan && mac.stepsPlanned == ReachFacts.longestPlan)
        let order = try #require(ReachFacts.install(Self.link(way: "mac", running: true, steps: [("order", .running)])))
        #expect(order.kind == .mac && order.step == .order && order.stop == nil && order.stepsPlanned == 1)
        #expect(order.since == nil)
    }

    /// **The stop is the model's own kind, each of them as it is**, for each kind of install: no kind is changed on
    /// the way, and a stop with no kind (the model gives one with each stop) is `other`.
    @Test func eachKindOfAStopPassesAsItIs() throws {
        for stop in InstallRecord.Stop.allCases {
            for way in ["linux", "mac"] {
                let facts = try #require(ReachFacts.install(Self.link(way: way, failed: true, steps: [("read", .failed)],
                                                                      planned: Self.joinIDs, stop: stop)))
                #expect(facts.state == .stopped && facts.stop == stop, "\(stop) \(way)")
            }
        }
        let bare = try #require(ReachFacts.install(Self.link(failed: true)))
        #expect(bare.state == .stopped && bare.stop == .other)
    }

    /// **The kind of a stop that `ssh` or the server said in words is the record's own** (`InstallRecord.Stop.of`,
    /// which reads a step's words as `InstallError.plain` does): the tests that those two find a line by, read from
    /// `MachineInstaller.swift`, so that a word that changes there fails here, and each of them with its kind.
    @Test func eachStopFromTheInstallersOwnWords() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FleetCore/MachineInstaller.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        func words(of function: String) throws -> [String] {
            let start = try #require(source.range(of: function))
            let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
            let body = String(source[start.upperBound..<end.lowerBound])
            let literal = try NSRegularExpression(pattern: #""([^"\\]*)""#)
            return literal.matches(in: body, range: NSRange(body.startIndex..., in: body))
                .map { (body as NSString).substring(with: $0.range(at: 1)) }
        }
        let unreached = try words(of: "static func unreached(_ said: String) -> Bool {")
        #expect(unreached == ["ssh: ", "connection refused", "timed out", "no route to host",
                              "could not resolve hostname", "network is unreachable", "kex_exchange_identification",
                              "during banner exchange", "answered 255.", "connection closed by ", " port "])
        let refused = try words(of: "static func keyRefused(_ line: String) -> Bool {")
        #expect(refused == ["permission denied (publickey", "too many authentication failures"])

        // As the installer gives a step's words to its error: `ssh`'s own line, with its capitals.
        func stop(_ says: String) -> InstallRecord.Stop {
            InstallRecord.Stop.of(InstallError.step("Example step", says))
        }
        for word in ["Connection refused", "Connection timed out", "No route to host",
                     "Could not resolve hostname example.com: nodename nor servname provided", "Network is unreachable"] {
            #expect(stop("ssh: connect to host 100.64.0.9 port 22: \(word)") == .serverUnreached, "\(word)")
        }
        #expect(stop("kex_exchange_identification: read: Connection reset by peer") == .serverUnreached)
        #expect(stop("ssh_exchange_identification: Connection closed during banner exchange") == .serverUnreached)
        #expect(stop("The server answered 255.") == .serverUnreached)
        #expect(stop("Connection closed by 100.64.0.9 port 22") == .serverUnreached)
        #expect(stop("root@100.64.0.9: Permission denied (publickey,password).") == .loginRefused)
        #expect(stop("Received disconnect from 100.64.0.9 port 22:2: Too many authentication failures") == .loginRefused)
        // A package mirror that timed out on the server is not this Mac failing to reach it: a step that failed.
        #expect(stop("E: Failed to fetch http://example.com/pool: Connection timed out") == .stepFailed)
        // The other kinds that the guide's lines name, each from the error that the install ends with.
        #expect(stop("Founderizer install stopped: no Tailscale auth key came in") == .installerStopped)
        #expect(stop(MachineInstaller.notThisMacs) == .hubNotOurs)
        #expect(InstallRecord.Stop.of(InstallError.needsPassword(.ssh)) == .needsSSHPassword)
        #expect(InstallRecord.Stop.of(InstallError.needsPassword(.sudo)) == .needsSudoPassword)
        #expect(InstallRecord.Stop.of(InstallError.timedOut("Example step")) == .timedOut)
        #expect(InstallRecord.Stop.of(InstallError.noClaimCode) == .noClaimCode)
        #expect(InstallRecord.Stop.of(InstallError.noChecklist) == .noChecklist)
        #expect(InstallRecord.Stop.of(InstallError.checkStopped("Example")) == .checkStopped)
        #expect(InstallRecord.Stop.of(InstallError.notRoot("ada")) == .notRoot)
        #expect(InstallRecord.Stop.of(InstallError.cannotStart("Example")) == .cannotStart)
        #expect(InstallRecord.Stop.of(MacLinkError.refused("Example")) == .macRefused)
        #expect(InstallRecord.Stop.of(MacLinkError.unreachable) == .macUnreachable)
        #expect(InstallRecord.Stop.of(MacLinkError.unreadable) == .macUnreadable)
        #expect(InstallRecord.Stop.of(HubError.unavailable) == .hubUnreached)
        #expect(InstallRecord.Stop.of(URLError(.timedOut)) == .hubUnreached)
        #expect(InstallRecord.Stop.of(HubError.invalidResponse) == .hubRefused)
    }

    /// **Only an install that stands stopped has a stop and a wait for the network**: one that runs again after a
    /// stop, that ended, or that its page ended has neither, whatever the model still holds.
    @Test func onlyAStoppedInstallHasAStop() throws {
        let waits = try #require(ReachFacts.install(Self.link(failed: true, steps: [("network", .failed)],
                                                              planned: Self.joinIDs, stop: .installerStopped,
                                                              waitsForNetwork: true)))
        #expect(waits.stop == .installerStopped && waits.waitsForNetwork && waits.step == .network)
        let refused = try #require(ReachFacts.install(Self.link(failed: true, job: .hub, stop: .networkKeyRefused,
                                                                waitsForNetwork: true)))
        #expect(refused.stop == .networkKeyRefused && refused.waitsForNetwork && refused.step == .none)
        let reached = try #require(ReachFacts.install(Self.link(failed: true, steps: [("read", .failed)],
                                                                planned: Self.joinIDs, stop: .serverUnreached)))
        #expect(reached.stop == .serverUnreached && !reached.waitsForNetwork && reached.step == .read)
        let running = try #require(ReachFacts.install(Self.link(running: true, steps: [("read", .running)],
                                                                planned: Self.joinIDs, stop: .stepFailed,
                                                                waitsForNetwork: true)))
        #expect(running.stop == nil && !running.waitsForNetwork)
        let done = try #require(ReachFacts.install(Self.link(ended: true, steps: Self.joinIDs.map { ($0, .done) },
                                                             planned: Self.joinIDs, stop: .other, waitsForNetwork: true)))
        #expect(done.stop == nil && !done.waitsForNetwork)
        let ended = try #require(ReachFacts.install(Self.link(steps: [("read", .running)], planned: Self.joinIDs,
                                                              stop: .timedOut, waitsForNetwork: true)))
        #expect(ended.state == .none && ended.stop == nil && !ended.waitsForNetwork)
    }

    // ------------------------------------------------------------ the kept records

    /// A record with these steps, as an install's log writes them: each step begins one second after the one
    /// before it, and one that ended does so half a second later.
    static func record(_ kind: InstallRecord.Kind, hub: String? = "http://100.64.0.7:8765/",
                       steps: [(String, InstallRecord.StepState)] = [], at seconds: Double = 0,
                       end: (inout InstallLog) -> Void = { _ in }) -> InstallRecord {
        var log = InstallLog(kind: kind, hub: hub, host: "203.0.113.9", launch: "example",
                             at: start.addingTimeInterval(seconds))
        for (index, step) in steps.enumerated() {
            log.note(step: step.0, state: .running, at: start.addingTimeInterval(seconds + Double(index)))
            if step.1 != .running {
                log.note(step: step.0, state: step.1, at: start.addingTimeInterval(seconds + Double(index) + 0.5))
            }
        }
        end(&log)
        return log.record
    }

    /// **Which record is the last install**: for a hub, the newest one for that hub's address, of any kind; with no
    /// hub, the newest install of a hub, with an address or without one.
    @Test func theLastInstallIsOfTheFleetThatTheAppShows() {
        let mine = "http://100.64.0.7:8765/", other = "http://100.64.0.9:8765/"
        let records = [Self.record(.join, hub: other, at: 50), Self.record(.mac, hub: mine, at: 40),
                       Self.record(.hub, hub: other, at: 30), Self.record(.join, hub: mine, at: 20),
                       Self.record(.hub, hub: nil, at: 10)]
        #expect(ReachFacts.lastRecord(in: records, hub: mine) == records[1])
        #expect(ReachFacts.lastRecord(in: records, hub: other) == records[0])
        #expect(ReachFacts.lastRecord(in: Array(records.dropFirst(2)), hub: mine) == records[3])
        // With no hub: the newest install of a hub, also one that stopped after its claim.
        #expect(ReachFacts.lastRecord(in: records, hub: nil) == records[2])
        #expect(ReachFacts.lastRecord(in: Array(records.dropFirst(3)), hub: nil) == records[4])
        // An address in another form is another hub, and no record is no last install.
        #expect(ReachFacts.lastRecord(in: records, hub: "http://100.64.0.7:8765") == nil)
        #expect(ReachFacts.lastRecord(in: [records[1], records[3]], hub: nil) == nil)
        #expect(ReachFacts.lastRecord(in: [], hub: mine) == nil && ReachFacts.lastRecord(in: [], hub: nil) == nil)
    }

    /// **A record's facts**: the step where it stood, its stop only for a record that says stopped, its counts, and
    /// the time of its last change.
    @Test func aRecordsFacts() {
        // A join that stopped at its second step.
        let stopped = Self.record(.join, steps: [("read", .done), ("network", .failed)]) {
            $0.stop(.serverUnreached, says: "This Mac could not reach 203.0.113.9 over SSH.", waitsForNetwork: false,
                    at: Self.start.addingTimeInterval(9))
        }
        #expect(ReachFacts.lastInstall(stopped)
                == .init(kind: .join, outcome: .stopped, stop: .serverUnreached, waitsForNetwork: false, step: .network,
                         stepsDone: 1, stepsPlanned: 4, lastChange: Self.start.addingTimeInterval(9)))
        // A hub's install that waits for the network, stopped before any step.
        let waiting = ReachFacts.lastInstall(Self.record(.hub, hub: nil) {
            $0.stop(.networkKeyRefused, says: nil, waitsForNetwork: true, at: Self.start.addingTimeInterval(2))
        })
        #expect(waiting.kind == .hub && waiting.stop == .networkKeyRefused && waiting.waitsForNetwork)
        #expect(waiting.step == .none && waiting.stepsDone == 0 && waiting.stepsPlanned == 9)
        // One that ended well: no step, no stop.
        let done = Self.record(.join, steps: ["read", "network", "join", "verify"].map { ($0, .done) }) {
            $0.done(at: Self.start.addingTimeInterval(60))
        }
        #expect(ReachFacts.lastInstall(done)
                == .init(kind: .join, outcome: .done, stop: nil, waitsForNetwork: false, step: .none, stepsDone: 4,
                         stepsPlanned: 4, lastChange: Self.start.addingTimeInterval(60)))
        // One that the app's end cut off, as a later start reads it: the step that ran, no stop, and its last sign.
        let cut = Self.record(.hub, steps: [("read", .done), ("network", .done), ("code", .running)]).cutOff()
        #expect(ReachFacts.lastInstall(cut)
                == .init(kind: .hub, outcome: .interrupted, stop: nil, waitsForNetwork: false, step: .code,
                         stepsDone: 2, stepsPlanned: 9, lastChange: Self.start.addingTimeInterval(2)))
        // One that its page ended, and one that runs.
        let ended = ReachFacts.lastInstall(Self.record(.join, steps: [("read", .running)]) {
            $0.cancel(at: Self.start.addingTimeInterval(5))
        })
        #expect(ended.outcome == .cancelled && ended.step == .read && ended.stop == nil)
        let runs = ReachFacts.lastInstall(Self.record(.join, steps: [("read", .done), ("network", .running)]))
        #expect(runs.outcome == .running && runs.step == .network && runs.stop == nil && runs.stepsDone == 1)
    }

    /// **A Mac's record names its own steps**: a name that no plan has is `other`, the counts are capped at the longest
    /// plan, and its planned steps are the steps that it has.
    @Test func aMacsRecordPassesOnlyTheFixedLists() {
        let many = (0..<20).map { ("Step \($0) on example-mac", InstallRecord.StepState.done) }
            + [("install_agent", .failed)]
        let mac = ReachFacts.lastInstall(Self.record(.mac, steps: many) {
            $0.stop(.macRefused, says: nil, at: Self.start.addingTimeInterval(99))
        })
        #expect(mac.kind == .mac && mac.step == .other && mac.stop == .macRefused)
        #expect(mac.stepsDone == ReachFacts.longestPlan && mac.stepsPlanned == ReachFacts.longestPlan)
        let order = ReachFacts.lastInstall(Self.record(.mac, steps: [("order", .running)]))
        #expect(order.step == .order && order.stepsDone == 0 && order.stepsPlanned == 1)
        // A record that says stopped with no kind is `other`, and a wait counts only with a stop.
        var bare = Self.record(.join)
        bare.outcome = .stopped
        #expect(ReachFacts.lastInstall(bare).stop == .other)
        bare.outcome = .cancelled
        bare.stop = .timedOut
        bare.waitsForNetwork = true
        #expect(ReachFacts.lastInstall(bare).stop == nil && !ReachFacts.lastInstall(bare).waitsForNetwork)
    }

    /// **The step names of a record are the names of an install's step**, with `none` for no step, and the two plans'
    /// counts are the plans' own.
    @Test func theRecordsStepsAreAnInstallsSteps() {
        #expect(InstallRecord.stepIDs + ["none"] == ReachFacts.InstallStepName.allCases.map(\.rawValue))
        for id in InstallRecord.StepID.allCases {
            #expect(ReachFacts.installStep(id.rawValue).rawValue == id.rawValue)
        }
        let target = InstallTarget(host: "100.64.0.9")
        #expect(ReachFacts.longestPlan
                == InstallPlan.hub(target: target, source: "https://example.com/founderizer.git", authKey: nil).steps.count)
        #expect(ReachFacts.joinPlan
                == InstallPlan.join(target: target, line: "curl -fsSL https://example.com/join | sh", code: "example",
                                    authKey: nil).steps.count)
    }

    /// **The seconds count from the record's last change**, and never below 0.
    @Test func theSecondsSinceTheRecordsLastChange() {
        let last = ReachFacts.lastInstall(Self.record(.join, steps: [("read", .done)]) {
            $0.done(at: Self.start.addingTimeInterval(30))
        })
        #expect(ReachFacts.seconds(since: last, now: Self.start.addingTimeInterval(90)) == 60)
        #expect(ReachFacts.seconds(since: last, now: Self.start) == 0)
        #expect(ReachFacts.seconds(since: nil, now: Self.start) == nil)
    }

    /// **A record's date is a number in a file, and it can be any number**: the age is 0 for a date after now, has
    /// an upper bound, and is nil for a date that is no number. `Int` of a number that is too large stops the app,
    /// so the bounds come before it.
    @Test func theAgeOfARecordWithADamagedDate() {
        let now = Self.start
        #expect(ReachFacts.seconds(from: now.addingTimeInterval(-75.9), to: now) == 75)
        #expect(ReachFacts.seconds(from: now.addingTimeInterval(600), to: now) == 0)
        #expect(ReachFacts.seconds(from: Date(timeIntervalSince1970: 1e300), to: now) == 0)
        #expect(ReachFacts.seconds(from: Date(timeIntervalSince1970: -1e300), to: now) == ReachFacts.mostSeconds)
        #expect(ReachFacts.seconds(from: .distantPast, to: now) == ReachFacts.mostSeconds)
        #expect(ReachFacts.seconds(from: Date(timeIntervalSince1970: -.infinity), to: now) == ReachFacts.mostSeconds)
        #expect(ReachFacts.seconds(from: Date(timeIntervalSince1970: .infinity), to: now) == 0)
        #expect(ReachFacts.seconds(from: Date(timeIntervalSince1970: .nan), to: now) == nil)
        // The same bound for the last install's record.
        let old = InstallRecord(kind: .hub, hub: nil, host: "203.0.113.9", launch: "example",
                                at: Date(timeIntervalSince1970: -1e300)).cutOff()
        #expect(ReachFacts.seconds(since: ReachFacts.lastInstall(old), now: now) == ReachFacts.mostSeconds)
        let far = InstallRecord(kind: .hub, hub: nil, host: "203.0.113.9", launch: "example",
                                at: Date(timeIntervalSince1970: 1e300)).cutOff()
        #expect(ReachFacts.seconds(since: ReachFacts.lastInstall(far), now: now) == 0)
    }

    /// One build's record at one of its ends.
    static func build(_ change: (inout BuildRecord) -> Void) -> BuildRecord {
        var record = BuildRecord(provider: .hetzner, use: .agent, hub: "http://100.64.0.7:8765/", name: "example-server-1",
                                 launch: "example", at: start)
        change(&record)
        return record
    }

    /// **The servers that never joined, by what each build left at its provider**: a build that joined, one that
    /// runs and one that left nothing do not count, whatever their hub.
    @Test func theBuildsThatNeverJoined() {
        let made = Self.build { $0.made(id: "100001"); $0.end(at: Self.start.addingTimeInterval(300)) }
        let cancelled = Self.build { $0.made(id: "100002"); $0.end(cancelled: true) }
        let cut = Self.build { $0.made(id: "100003") }.cutOff()
        let unknown = Self.build { _ in }.cutOff()
        let left = Self.build {
            $0.callEnded(with: CloudError.leftBehind(.hetzner, reason: "Example", left: ["the server"])); $0.end()
        }
        let unreachable = Self.build { $0.callEnded(with: CloudError.unreachable(.hetzner)); $0.end() }
        let refused = Self.build { $0.callEnded(with: CloudError.noRoom(.hetzner)); $0.end() }
        let joined = Self.build { $0.made(id: "100004"); $0.joined() }
        let runs = Self.build { $0.made(id: "100005") }
        let unjoined = [made, cancelled, cut, unknown, left, unreachable].filter { $0.isUnjoined }
        #expect(unjoined.count == 6)
        let none = [refused, joined, runs].filter { $0.isUnjoined }
        #expect(none.isEmpty)
        let counts = ReachFacts.unjoined([made, cancelled, cut, unknown, left, unreachable, refused, joined, runs])
        #expect(counts == .init(server: 3, leftBehind: 1, notKnown: 2) && counts.total == 6)
        #expect(ReachFacts.unjoined([refused, joined, runs]) == .init() && ReachFacts.unjoined([]).total == 0)
        // A first run's build has no hub, and it counts as each other one does.
        let first = BuildRecord(provider: .vultr, use: .hub, hub: nil, name: "example-hub", launch: "example",
                                at: Self.start).cutOff()
        #expect(ReachFacts.unjoined([first]) == .init(notKnown: 1))
        // The newest of them, for its age: a record that joined, runs or left nothing is not looked at.
        #expect(ReachFacts.newestUnjoined([made, cancelled, refused, joined, runs])
                == max(made.lastChange, cancelled.lastChange))
        #expect(ReachFacts.newestUnjoined([made, joined, runs]) == made.lastChange)
        #expect(ReachFacts.newestUnjoined([refused, joined, runs]) == nil && ReachFacts.newestUnjoined([]) == nil)
    }
    #endif
}
