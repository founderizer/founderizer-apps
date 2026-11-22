import Foundation
import Testing
@testable import FleetCore

/// Error reports (the owner's "Yes, as drawn" of 16 November 2026): the switch's reading, the Mac's report of the
/// contract (`POST <channel>/api/errors`, from "mac"), the crash entries that MetricKit's call stack trees become, and
/// the one rule of where our own site is. Most of these are about what must **not** go: no text of a crash, no name of
/// a binary, and no value outside the contract, which would make the site refuse the whole report.
struct ErrorReportsTests {
    /// This app's own executable as MetricKit writes it (upper case), and as the report writes it.
    private static let ownUpper = "3F2A1B4C-5D6E-4F70-8192-A3B4C5D6E7F8"
    private static let own = ownUpper.lowercased()
    private static let fleet = "0123456789abcdef"
    private static let when = Date(timeIntervalSince1970: 1_763_300_000)

    private func crash(signal: Int? = 6, type: Int? = 10, code: Int? = 0, frames: [ErrorReport.Frame] = [.lib],
                       count: Int = 1, first: Int = 1_763_300_000, last: Int = 1_763_300_000) -> ErrorReport.Crash {
        ErrorReport.Crash(signal: signal, type: type, code: code, frames: frames, count: count, first: first, last: last)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // ------------------------------------------------------------ the switch

    /// **The first run's answer reaches a hub, and only a hub's receipt ends its wait** (the page "Help improve
    /// Founderizer", 18 November 2026). The page stands before any hub: a hub that does not offer the switch gets
    /// nothing, a call that fails keeps the answer for the next hub, and the receipt ends the wait while the card keeps
    /// its check mark. A press while a call runs is the owner's newer answer, and it still waits after that call. A
    /// first run that starts again ends the wait with no send, and the check mark stays.
    @Test func theFirstRunsAnswerWaitsUntilAHubTookIt() async throws {
        let defaults = TestDefaults("FirstRunReportsTests")
        #expect(FirstRunReports.chosen(in: defaults) == nil)
        #expect(await !FirstRunReports.deliver(offered: true, in: defaults) { _ in Issue.record("no answer, no call") })

        FirstRunReports.choose(true, in: defaults)
        var sent: [Bool] = []
        #expect(await !FirstRunReports.deliver(offered: false, in: defaults) { sent.append($0) })
        #expect(await !FirstRunReports.deliver(offered: true, in: defaults) { _ in throw HubError.invalidResponse })
        #expect(sent.isEmpty && FirstRunReports.waiting(in: defaults) == true)

        #expect(await FirstRunReports.deliver(offered: true, in: defaults) { sent.append($0) })
        #expect(sent == [true] && FirstRunReports.waiting(in: defaults) == nil)
        #expect(FirstRunReports.chosen(in: defaults) == true)

        FirstRunReports.choose(true, in: defaults)
        #expect(await FirstRunReports.deliver(offered: true, in: defaults) { _ in FirstRunReports.choose(false, in: defaults) })
        #expect(FirstRunReports.waiting(in: defaults) == false && FirstRunReports.chosen(in: defaults) == false)

        FirstRunReports.forget(in: defaults)
        #expect(await !FirstRunReports.deliver(offered: true, in: defaults) { _ in Issue.record("a forgotten answer goes nowhere") })
        #expect(FirstRunReports.chosen(in: defaults) == false)
    }

    /// The hub's answer is `{"send", "db"}`: both, of their kinds, and the generation that was asked.
    @Test func theSwitchIsReadFromTheHubsAnswer() throws {
        let on = try JSONDecoder().decode(ErrorReportsState.self, from: Data(#"{"send": true, "db": "g1"}"#.utf8))
        #expect(on == ErrorReportsState(send: true, db: "g1"))
        try on.validate(database: "g1")
        let off = try JSONDecoder().decode(ErrorReportsState.self, from: Data(#"{"send": false, "db": "g1"}"#.utf8))
        #expect(!off.send)
        #expect(throws: HubError.self) { try off.validate(database: "g2") }
        for bad in [#"{"send": true}"#, #"{"db": "g1"}"#, #"{"send": null, "db": "g1"}"#, #"{"send": "yes", "db": "g1"}"#,
                    #"{"send": 1.5, "db": "g1"}"#, #"{"send": true, "db": null}"#, #"[]"#] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(ErrorReportsState.self, from: Data(bad.utf8)) }
        }
        #expect(ErrorReportsState.feature == "error_reports")
    }

    /// The read of the switch, against a hub that answers once: its route with this generation, and an answer of
    /// another generation is no answer.
    @Test func theReadAsksTheRouteOfThisGeneration() async throws {
        let hub = try OneAnswer(status: "200 OK") { _ in #"{"send": true, "db": "g1"}"# }
        let state = try await HubClient(reads: HubReads()).errorReports(hub: URL(string: "http://127.0.0.1:\(hub.port)/")!,
                                                                       database: "g1")
        #expect(state.send)
        let message = String(decoding: hub.received, as: UTF8.self)
        #expect(message.hasPrefix("GET /ui/error-reports?db=g1 HTTP/1.1\r\n"))
        let other = try OneAnswer(status: "200 OK") { _ in #"{"send": true, "db": "g0"}"# }
        await #expect(throws: HubError.self) {
            _ = try await HubClient(reads: HubReads()).errorReports(hub: URL(string: "http://127.0.0.1:\(other.port)/")!,
                                                                   database: "g1")
        }
    }

    /// A generation that the hub no longer has is its 409 `hub_changed`: a refusal, never a reading.
    @Test func aReadOfAnotherGenerationIsTheHubsRefusal() async throws {
        let hub = try OneAnswer(status: "409 Conflict") { _ in #"{"error": "hub generation changed; refresh state", "code": "hub_changed"}"# }
        do {
            _ = try await HubClient(reads: HubReads()).errorReports(hub: URL(string: "http://127.0.0.1:\(hub.port)/")!,
                                                                   database: "g0")
            Issue.record("a 409 was taken for a reading")
        } catch HubError.refusal(let refusal) {
            #expect(refusal.status == 409 && refusal.code == "hub_changed")
        }
    }

    /// The write is an owner command as `POST /ui/releases/auto` is: its request id, the generation, this Mac's client,
    /// and the one field `send`; a receipt of another request is no answer.
    @Test func theWriteIsAnOwnerCommandWithItsRequestID() async throws {
        let id = UUID()
        let receipt = #"{"ok": true, "request_id": "\#(id.uuidString.lowercased())", "client": "mac-1", "replayed": false, "send": false}"#
        let hub = try OneAnswer(status: "200 OK") { _ in receipt }
        let answer = try await HubClient(reads: HubReads()).errorReports(
            false, hub: URL(string: "http://127.0.0.1:\(hub.port)/")!, database: "g1", client: "mac-1", requestID: id)
        #expect(answer.send == false)
        let message = String(decoding: hub.received, as: UTF8.self)
        let head = message.lowercased()
        #expect(message.hasPrefix("POST /ui/error-reports HTTP/1.1\r\n"))
        #expect(head.contains("\r\ncontent-type: application/json"))
        #expect(head.contains("\r\nx-fleet-client: mac-1"))
        let body = try json(OneAnswer.body(of: hub.received))
        #expect(Set(body.keys) == ["db", "request_id", "send"])
        #expect(body["db"] as? String == "g1" && body["request_id"] as? String == id.uuidString.lowercased())
        #expect(body["send"] as? Bool == false)

        let other = try OneAnswer(status: "200 OK") { _ in #"{"ok": true, "request_id": "\#(UUID().uuidString.lowercased())", "replayed": false}"# }
        await #expect(throws: HubError.self) {
            _ = try await HubClient(reads: HubReads()).errorReports(
                true, hub: URL(string: "http://127.0.0.1:\(other.port)/")!, database: "g1", client: "mac-1")
        }
    }

    /// **The switch shows only what the hub said** (the screen review of 16 November 2026): a receipt that names another
    /// value than the one asked is no answer, so the switch keeps the hub's reading; one that names the value asked is it.
    @Test func aReceiptOfAnotherValueIsNoAnswer() async throws {
        let id = UUID()
        let head = #"{"ok": true, "request_id": "\#(id.uuidString.lowercased())", "client": "mac-1", "replayed": false, "send": "#
        let off = head + "false}", on = head + "true}"
        let other = try OneAnswer(status: "200 OK") { _ in off }
        await #expect(throws: HubError.self) {
            _ = try await HubClient(reads: HubReads()).errorReports(
                true, hub: URL(string: "http://127.0.0.1:\(other.port)/")!, database: "g1", client: "mac-1", requestID: id)
        }
        let same = try OneAnswer(status: "200 OK") { _ in on }
        let answer = try await HubClient(reads: HubReads()).errorReports(
            true, hub: URL(string: "http://127.0.0.1:\(same.port)/")!, database: "g1", client: "mac-1", requestID: id)
        #expect(answer.send == true)
    }

    /// A refusal carries the hub's words, which the row shows as its warning.
    @Test func aRefusedWriteCarriesTheHubsWords() async throws {
        let hub = try OneAnswer(status: "409 Conflict") { _ in #"{"error": "hub generation changed; refresh state"}"# }
        do {
            _ = try await HubClient(reads: HubReads()).errorReports(
                true, hub: URL(string: "http://127.0.0.1:\(hub.port)/")!, database: "g1", client: "mac-1")
            Issue.record("a 409 was taken for an answer")
        } catch HubError.refusal(let refusal) {
            #expect(refusal.status == 409 && refusal.hubWords == "hub generation changed; refresh state")
        }
    }

    // ------------------------------------------------------------ the report's caps and patterns

    @Test func theReportHasTheContractsKeysAndNothingElse() throws {
        let report = try #require(ErrorReport(fleet: Self.fleet, version: "0.1.285 (286)", system: "macOS 26.6.2",
                                              crashes: [crash(signal: nil, type: nil, code: nil)]))
        let body = try json(report.body())
        #expect(Set(body.keys) == ["fleet", "from", "version", "system", "crashes"])
        #expect(body["from"] as? String == "mac" && body["fleet"] as? String == Self.fleet)
        #expect(body["version"] as? String == "0.1.285 (286)" && body["system"] as? String == "macOS 26.6.2")
        let entry = try #require((body["crashes"] as? [[String: Any]])?.first)
        #expect(Set(entry.keys) == ["signal", "type", "code", "frames", "count", "first", "last"])
        // A number that the crash does not have goes as null: each key of the contract is there.
        #expect(entry["signal"] is NSNull && entry["type"] is NSNull && entry["code"] is NSNull)
        let sent = String(decoding: try report.body(), as: UTF8.self)
        #expect(sent.contains(#""signal":null"#) && sent.contains(#""type":null"#) && sent.contains(#""code":null"#))
        let frame = try #require((entry["frames"] as? [[String: Any]])?.first)
        #expect(frame.count == 2 && frame["image"] as? String == "lib" && frame["offset"] as? Int == 0)
        // An optional key at the top is left out, never null: a report with no system has no `system`.
        let bare = try #require(ErrorReport(fleet: Self.fleet, version: "0.1.285 (286)", system: nil, crashes: [crash()]))
        let bareBody = try bare.body()
        #expect(Set(try json(bareBody).keys) == ["fleet", "from", "version", "crashes"])
        #expect(!String(decoding: bareBody, as: UTF8.self).contains("system"))
        // The version as AppVersion names the build that runs, and the system as the report names it.
        #expect(ErrorReport.version(of: AppVersion(name: "0.1.285", build: 286)) == "0.1.285 (286)")
        #expect(ErrorReport.version(of: nil) == nil)
        #expect(ErrorReport.runningSystem.range(of: #"^macOS [0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil)
    }

    @Test func aFleetOrAVersionOutsideItsPatternMakesNoReport() {
        let one = [crash()]
        for fleet in [nil, "", "0123456789ABCDEF", "0123456789abcde", "0123456789abcdef0", "0123456789abcdeg",
                      "0123456789abcdef\n"] {
            #expect(ErrorReport(fleet: fleet, version: "0.1.285 (286)", system: nil, crashes: one) == nil)
        }
        // The version is MAC_VERSION of our site, from the first character to the last: one of another form would make
        // our site refuse each report, the day too.
        for version in [nil, "", String(repeating: "1", count: 41), "0.1.285/286", "0.1.285\n(286)", "0.1.285\n",
                        "0.1.285 «286»", "1", "0.1.285", "0.1.285 (286)\n", "v0.1.285 (286)", "0.1.285 (286) x",
                        "0.1.2.3.4 (5)", "1234567.1 (2)", "0.1 (1234567890)"] {
            #expect(ErrorReport(fleet: Self.fleet, version: version, system: nil, crashes: one) == nil, "\(String(describing: version))")
        }
        #expect(ErrorReport(fleet: Self.fleet, version: "999999.999999.999999.999999 (999999999)", system: nil, crashes: one) != nil)
        #expect(ErrorReport(fleet: Self.fleet, version: "1.2 (3)", system: nil, crashes: one) != nil)
        // An image's id ends where it ends: a final line break is no id (ICU's `$` would take one).
        #expect(ErrorReport.uuid("01234567-89AB-CDEF-0123-456789ABCDEF") == "01234567-89ab-cdef-0123-456789abcdef")
        #expect(ErrorReport.uuid("01234567-89ab-cdef-0123-456789abcdef\n") == nil)
        #expect(ErrorReport(fleet: Self.fleet, version: "0.1.285 (286)", system: nil, crashes: []) == nil)
        // The system is optional: one outside SYSTEM, our site's one word and its version number, is left out, and the
        // report still goes.
        for system in ["macOS/26", "macOS 26\n", String(repeating: "x", count: 41), "Debian GNU Linux 12",
                       String(repeating: "x", count: 17), "macOS 26.6.2.1.0", "macOS 12345", "macOS26", " macOS 26"] {
            #expect(ErrorReport(fleet: Self.fleet, version: "0.1.285 (286)", system: system, crashes: one)?.system == nil)
        }
        #expect(ErrorReport(fleet: Self.fleet, version: "0.1.285 (286)", system: nil, crashes: one)?.system == nil)
        #expect(ErrorReport(fleet: Self.fleet, version: "0.1.285 (286)", system: "Ubuntu 24.04", crashes: one)?.system == "Ubuntu 24.04")
    }

    /// Each value outside the contract would make the site refuse the whole report, so such an entry never goes.
    @Test func aCrashOutsideTheCapsIsLeftOut() {
        let uuid = ErrorReport.Frame(image: Self.own, offset: 42)
        #expect(crash(frames: [uuid, .lib]).checked != nil)
        #expect(crash(signal: 0, type: 0, code: -((1 << 53) - 1)).checked != nil)
        #expect(crash(signal: 64, type: 1000, code: (1 << 53) - 1, count: 1_000_000_000,
                      first: 1_600_000_000, last: 4_000_000_000).checked != nil)
        #expect(crash(frames: Array(repeating: uuid, count: 32)).checked != nil)
        #expect(crash(frames: []).checked != nil)
        let wrong: [ErrorReport.Crash] = [
            crash(signal: 65), crash(signal: -1), crash(type: 1001), crash(type: -1), crash(code: 1 << 53),
            crash(count: 0), crash(count: 1_000_000_001), crash(first: 1_599_999_999), crash(last: 4_000_000_001),
            crash(first: 1_763_300_001, last: 1_763_300_000), crash(frames: Array(repeating: uuid, count: 33)),
            crash(frames: [.init(image: Self.ownUpper, offset: 42)]), crash(frames: [.init(image: Self.own, offset: -1)]),
            crash(frames: [.init(image: Self.own, offset: (1 << 40) + 1)]), crash(frames: [.init(image: "lib", offset: 5)]),
            crash(frames: [.init(image: "libsystem_kernel.dylib", offset: 0)]),
        ]
        for entry in wrong { #expect(entry.checked == nil, "\(entry)") }
        #expect(ErrorReport(fleet: Self.fleet, version: "0.1.285 (286)", system: nil, crashes: wrong) == nil)
        #expect(ErrorReport(fleet: Self.fleet, version: "0.1.285 (286)", system: nil, crashes: wrong + [crash()])?.crashes == [crash()])
    }

    @Test func atMostTwentyCrashesGoTheOnesSeenLast() throws {
        let many = (0..<25).map { crash(signal: $0, first: 1_763_300_000 + $0, last: 1_763_300_000 + $0) }
        let report = try #require(ErrorReport(fleet: Self.fleet, version: "0.1.285 (286)", system: nil, crashes: many))
        #expect(report.crashes.count == 20)
        #expect(report.crashes.map(\.signal) == (5..<25).map { Int?($0) })
    }

    /// The largest report that this Mac can make: twenty crashes of 32 frames of its own, each at the highest offset.
    @Test func theLargestReportFitsTheSitesLimit() throws {
        let frames = Array(repeating: ErrorReport.Frame(image: Self.own, offset: 1 << 40), count: 32)
        let crashes = (0..<20).map {
            crash(signal: 64, type: 1000, code: -((1 << 53) - 1) + $0, frames: frames, count: 1_000_000_000,
                  first: 1_600_000_000, last: 4_000_000_000)
        }
        let report = try #require(ErrorReport(fleet: Self.fleet, version: "999999.999999.999999.999999 (999999999)",
                                              system: "Abcdefghijklmnop 9999.9999.9999.9999", crashes: crashes))
        #expect(report.crashes.count == 20)
        #expect(try report.body().count <= ErrorReport.maxBytes)
    }

    // ------------------------------------------------------------ MetricKit's call stack tree

    /// A call stack tree in the shape MetricKit writes it for a crash (`callStackPerThread`): a thread that did not
    /// crash, with this app's frames in it, and the crashed one, from `__pthread_kill` down to `start`. Every frame has
    /// the binary's name and its address, which must not leave.
    private static let tree = """
    {
      "callStackPerThread" : true,
      "callStacks" : [
        {
          "threadAttributed" : false,
          "callStackRootFrames" : [
            { "binaryUUID" : "\(ownUpper)", "offsetIntoBinaryTextSegment" : 999001, "sampleCount" : 1,
              "binaryName" : "Founderizer", "address" : 4300000001 }
          ]
        },
        {
          "threadAttributed" : true,
          "callStackRootFrames" : [
            { "binaryUUID" : "6D0A4C8E-1B2F-4A3D-9E5C-7F8A9B0C1D2E", "offsetIntoBinaryTextSegment" : 37468,
              "sampleCount" : 1, "binaryName" : "libsystem_kernel.dylib", "address" : 7212834596,
              "subFrames" : [
                { "binaryUUID" : "1C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F", "offsetIntoBinaryTextSegment" : 26820,
                  "sampleCount" : 1, "binaryName" : "libsystem_pthread.dylib", "address" : 7212801234,
                  "subFrames" : [
                    { "binaryUUID" : "\(ownUpper)", "offsetIntoBinaryTextSegment" : 165304, "sampleCount" : 1,
                      "binaryName" : "Founderizer", "address" : 4372307128,
                      "subFrames" : [
                        { "binaryUUID" : "\(ownUpper)", "offsetIntoBinaryTextSegment" : 162020, "sampleCount" : 1,
                          "binaryName" : "Founderizer", "address" : 4372303844,
                          "subFrames" : [
                            { "binaryUUID" : "8B9C0D1E-2F3A-4B5C-9D6E-7F8091A2B3C4", "offsetIntoBinaryTextSegment" : 6948,
                              "sampleCount" : 1, "binaryName" : "dyld", "address" : 7212834000 }
                          ]
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
    """

    @Test func theCrashedThreadsFramesBecomeUUIDsAndOffsetsAndEveryOtherBinaryIsLib() throws {
        let entry = try #require(ErrorReport.crash(stackTree: Data(Self.tree.utf8), signal: 6, type: 10, code: 0,
                                                   at: Self.when, own: [Self.ownUpper]))
        #expect(entry.frames == [.lib, .lib, .init(image: Self.own, offset: 165304), .init(image: Self.own, offset: 162020), .lib])
        #expect(entry.signal == 6 && entry.type == 10 && entry.code == 0)
        #expect(entry.count == 1 && entry.first == 1_763_300_000 && entry.last == 1_763_300_000)
        // A binary that is not this app's own executable is "lib", even one that was this app's in another build.
        let other = try #require(ErrorReport.crash(stackTree: Data(Self.tree.utf8), signal: 6, type: 10, code: 0,
                                                   at: Self.when, own: ["99999999-9999-4999-8999-999999999999"]))
        #expect(other.frames == Array(repeating: .lib, count: 5))
    }

    /// No text of the crash leaves: no binary's name, no address, no key of the tree but the two that it reads.
    @Test func noTextOfTheCrashLeaves() throws {
        let entry = try #require(ErrorReport.crash(stackTree: Data(Self.tree.utf8), signal: 11, type: 1, code: 1,
                                                   at: Self.when, own: [Self.own]))
        let report = try #require(ErrorReport(fleet: Self.fleet, version: "0.1.285 (286)", system: "macOS 26.6.2",
                                              crashes: [entry]))
        let sent = String(decoding: try report.body(), as: UTF8.self)
        for never in ["Founderizer", "libsystem", "dylib", "dyld", "binaryName", "address", "sampleCount", "subFrames",
                      "threadAttributed", "4372307128", "7212834596", "999001", "6d0a4c8e", "6D0A4C8E"] {
            #expect(!sent.contains(never), "\(never) left in \(sent)")
        }
        #expect(sent.contains(#""image":"\#(Self.own)""#))
    }

    @Test func atMost32FramesGoAndATreeWithNoCrashedThreadHasNone() throws {
        var frame = #"{"binaryUUID": "\#(Self.ownUpper)", "offsetIntoBinaryTextSegment": 40}"#
        for depth in (0..<39).reversed() {
            frame = #"{"binaryUUID": "\#(Self.ownUpper)", "offsetIntoBinaryTextSegment": \#(depth), "subFrames": [\#(frame)]}"#
        }
        let deep = #"{"callStacks": [{"threadAttributed": true, "callStackRootFrames": [\#(frame)]}]}"#
        let entry = try #require(ErrorReport.crash(stackTree: Data(deep.utf8), signal: 6, type: nil, code: nil,
                                                   at: Self.when, own: [Self.own]))
        #expect(entry.frames.count == 32)
        #expect(entry.frames.map(\.offset) == Array(0..<32))
        for tree in [#"{"callStacks": [{"threadAttributed": false, "callStackRootFrames": [\#(frame)]}]}"#,
                     #"{"callStacks": []}"#, "not json", #"{"callStacks": [{"threadAttributed": true}]}"#] {
            let empty = try #require(ErrorReport.crash(stackTree: Data(tree.utf8), signal: 6, type: nil, code: nil,
                                                       at: Self.when, own: [Self.own]))
            #expect(empty.frames.isEmpty)
        }
    }

    @Test func aFrameOrANumberOutsideTheContractIsLeftOutOfTheEntry() throws {
        let tree = """
        {"callStacks": [{"threadAttributed": true, "callStackRootFrames": [
          {"binaryUUID": "\(Self.ownUpper)", "offsetIntoBinaryTextSegment": \(1 << 41), "subFrames": [
            {"binaryUUID": "\(Self.ownUpper)", "offsetIntoBinaryTextSegment": 12.5, "subFrames": [
              {"binaryUUID": "not-a-uuid", "offsetIntoBinaryTextSegment": 7, "subFrames": [
                {"binaryUUID": "\(Self.ownUpper)", "offsetIntoBinaryTextSegment": "8"}]}]}]}]}]}
        """
        let entry = try #require(ErrorReport.crash(stackTree: Data(tree.utf8), signal: 99, type: 5000, code: 1 << 60,
                                                   at: Self.when, own: [Self.own, "not-a-uuid"]))
        #expect(entry.frames == Array(repeating: .lib, count: 4))
        #expect(entry.signal == nil && entry.type == nil && entry.code == nil)
        #expect(entry.checked == entry)
        // A clock outside the contract's years gives no entry.
        for wrong in [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 4_000_000_001)] {
            #expect(ErrorReport.crash(stackTree: Data(Self.tree.utf8), signal: 6, type: nil, code: nil, at: wrong,
                                      own: [Self.own]) == nil)
        }
    }

    @Test func identicalCrashesAreOneEntryWithTheirCountFirstAndLast() {
        let one = crash(first: 1_763_300_000, last: 1_763_300_000)
        let again = crash(first: 1_763_300_500, last: 1_763_300_500)
        let earlier = crash(count: 3, first: 1_763_200_000, last: 1_763_250_000)
        let another = crash(signal: 11, first: 1_763_300_100, last: 1_763_300_100)
        let merged = ErrorReport.merged([one, another, again, earlier])
        #expect(merged == [crash(count: 5, first: 1_763_200_000, last: 1_763_300_500), another])
        #expect(ErrorReport.merged([crash(count: 999_999_999), crash(count: 5)]) == [crash(count: 1_000_000_000)])
        // Other frames, another type or another code are another crash.
        #expect(ErrorReport.merged([one, crash(frames: []), crash(type: 1), crash(code: 2)]).count == 4)
    }

    @Test func thisAppsOwnImagesAreTheRunningBuildAndTheBuildsBeforeIt() {
        let older = (0..<10).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
        let images = ErrorReport.ownImages(running: Self.ownUpper, kept: [older[0].uppercased(), "nonsense", Self.own] + older)
        #expect(images == [Self.own] + older.prefix(7))
        #expect(ErrorReport.ownImages(running: nil, kept: []) == [])
        #expect(ErrorReport.ownImages(running: "nonsense", kept: [older[1]]) == [older[1]])
        // The program that runs here has an LC_UUID of the contract's form.
        let running = ErrorReport.runningImage
        #expect(running.map { ErrorReport.uuid($0) == $0 } == true)
    }

    // ------------------------------------------------------------ what waits for the next start

    @Test func theKeptFileHoldsOnlyCheckedEntriesForItsUserAlone() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("error-reports-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("error-reports.json")
        #expect(ErrorReport.kept(file).isEmpty)
        try ErrorReport.keep([crash(), crash(), crash(signal: 99)], in: file)
        #expect(ErrorReport.kept(file) == [crash(count: 2)])
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        // An entry that the file holds and that is no longer one of the contract is left out when it is read.
        try Data(#"[{"signal": 99, "type": null, "code": null, "frames": [], "count": 1, "first": 1763300000, "last": 1763300000}, {"signal": 6, "type": 10, "code": 0, "frames": [{"image": "lib", "offset": 0}], "count": 1, "first": 1763300000, "last": 1763300000}]"#.utf8).write(to: file)
        #expect(ErrorReport.kept(file) == [crash()])
        try Data("not json".utf8).write(to: file)
        #expect(ErrorReport.kept(file).isEmpty)
        try Data(count: 2 * ErrorReport.maxBytes + 1).write(to: file)
        #expect(ErrorReport.kept(file).isEmpty)
        // No crash is no file.
        try ErrorReport.keep([crash()], in: file)
        try ErrorReport.keep([], in: file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try ErrorReport.keep([crash()], in: file)
        ErrorReport.forget(file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aFolderAtTheKeptFilesNameStaysWithWhatIsInItAndALinkGoesAlone() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("error-reports-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("error-reports.json")
        let inside = file.appendingPathComponent("another-program.txt")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        try Data("kept by another program".utf8).write(to: inside)
        #expect(ErrorReport.kept(file).isEmpty)
        ErrorReport.forget(file)
        #expect(throws: (any Error).self) { try ErrorReport.keep([crash()], in: file) }
        #expect(ErrorReport.settle([crash()], carriedKept: true, after: nil, in: file).isEmpty)
        #expect(FileManager.default.contents(atPath: inside.path) == Data("kept by another program".utf8))
        // A link at the name goes, and the file behind it stays as it was.
        let behind = folder.appendingPathComponent("behind.json")
        try ErrorReport.keep([crash()], in: behind)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: behind)
        ErrorReport.forget(file)
        #expect((try? FileManager.default.attributesOfItem(atPath: file.path)) == nil)
        #expect(ErrorReport.kept(behind) == [crash()])
    }

    // ------------------------------------------------------------ where it goes

    @Test func theReportGoesToTheFleetsOwnChannelAndOursWhenItHasNone() throws {
        #expect(try ErrorReportClient.endpoint(channel: nil).absoluteString == "https://platform.founderizer.com/api/errors")
        #expect(try ErrorReportClient.endpoint(channel: " ").absoluteString == "https://platform.founderizer.com/api/errors")
        #expect(try ErrorReportClient.endpoint(channel: "https://staging.platform.founderizer.com").absoluteString
            == "https://staging.platform.founderizer.com/api/errors")
        _ = try ErrorReportClient.endpoint(channel: "HTTPS://Staging.Platform.Founderizer.com")
        for bad in ["http://platform.founderizer.com", "http://staging.platform.founderizer.com", "https://example.com",
                    "https://platform.founderizer.com.example.net", "https://xplatform.founderizer.com", "ftp://platform.founderizer.com", "https://",
                    "not a url", "https://user:pw@platform.founderizer.com", "https://platform.founderizer.com?x=1", "https://platform.founderizer.com#x"] {
            #expect(throws: ErrorReportError.badChannel) { try ErrorReportClient.endpoint(channel: bad) }
        }
    }

    /// The rule is one function now, and Report a problem goes where it went: the same address for every channel that
    /// it took, and a refusal for every channel that it refused.
    @Test func reportAProblemGoesWhereItWent() throws {
        let taken = [nil, "", "  ", "https://platform.founderizer.com", "https://staging.platform.founderizer.com", "https://platform.founderizer.com/"]
        let addresses = try taken.map { try ProblemReportClient.endpoint(channel: $0).absoluteString }
        #expect(addresses == ["https://platform.founderizer.com/api/report", "https://platform.founderizer.com/api/report",
                              "https://platform.founderizer.com/api/report", "https://platform.founderizer.com/api/report",
                              "https://staging.platform.founderizer.com/api/report", "https://platform.founderizer.com/api/report"])
        for channel in taken + ["HTTPS://Staging.Platform.Founderizer.com"] {
            #expect(try ErrorReportClient.endpoint(channel: channel).absoluteString
                == ProblemReportClient.endpoint(channel: channel).absoluteString.replacingOccurrences(of: "api/report", with: "api/errors"))
        }
        for bad in ["http://platform.founderizer.com", "https://example.com", "https://platform.founderizer.com.example.net",
                    "https://xplatform.founderizer.com", "ftp://platform.founderizer.com", "https://", "not a url",
                    "https://user:pw@platform.founderizer.com", "https://platform.founderizer.com?x=1"] {
            #expect(throws: ProblemReportError.self) { try ProblemReportClient.endpoint(channel: bad) }
        }
        #expect(OurSite.isOurs("platform.founderizer.com") && OurSite.isOurs("A.Platform.Founderizer.COM"))
        #expect(!OurSite.isOurs("xplatform.founderizer.com") && !OurSite.isOurs("platform.founderizer.com.example.net"))
        #expect(!OurSite.isOurs("founderizer.com") && !OurSite.isOurs("www.founderizer.com"))   // the marketing site
    }

    /// The one request to our site, as the site gets it: its address, POST, JSON, the report's own body, and no key,
    /// no cookie and no header of the fleet.
    @Test func theRequestCarriesTheReportAndNothingElse() async throws {
        let report = try #require(ErrorReport(fleet: Self.fleet, version: "0.1.285 (286)", system: "macOS 26.6.2",
                                              crashes: [crash(frames: [.init(image: Self.own, offset: 165304), .lib])]))
        try await ErrorReportClient(protocolClasses: [ErrorSite.self])
            .send(report, channel: "https://errors-ok.platform.founderizer.com")
        let asked = try #require(ErrorSite.asked(host: "errors-ok.platform.founderizer.com").first)
        #expect(asked.url == "https://errors-ok.platform.founderizer.com/api/errors")
        #expect(asked.method == "POST")
        #expect(asked.headers["content-type"] == "application/json" && asked.headers["accept"] == "application/json")
        #expect(asked.headers["authorization"] == nil && asked.headers["cookie"] == nil)
        #expect(asked.headers[AppUpdate.fleetHeader.lowercased()] == nil)
        #expect(asked.body == (try report.body()))
    }

    @Test func everyAnswerButA200IsAFailedSend() async throws {
        let report = try #require(ErrorReport(fleet: Self.fleet, version: "0.1.285 (286)", system: nil, crashes: [crash()]))
        for status in [400, 429, 500] {
            await #expect(throws: ErrorReportError.refused(status)) {
                try await ErrorReportClient(protocolClasses: [ErrorSite.self])
                    .send(report, channel: "https://status-\(status).platform.founderizer.com")
            }
        }
        // A redirect is an answer, never a second request: the other site sees nothing.
        await #expect(throws: ErrorReportError.refused(307)) {
            try await ErrorReportClient(protocolClasses: [RedirectingSite.self]).send(report, channel: nil)
        }
        let asked = RedirectingSite.asked()
        #expect(asked.contains("https://platform.founderizer.com/api/errors"))
        #expect(!asked.contains { $0.hasPrefix("https://example.com") })
        // A channel that is not ours sends nothing at all.
        await #expect(throws: ErrorReportError.badChannel) {
            try await ErrorReportClient(protocolClasses: [ErrorSite.self]).send(report, channel: "https://example.com")
        }
        #expect(ErrorSite.asked(host: "example.com").isEmpty)
    }

    /// The privacy page's item about error reports (its anchor `error-reports`), in the language of the app's words.
    /// **A payload that our site refuses is dropped, and one that may go later is kept**: 400 (and every other answer
    /// but 429 and 5xx) deletes the kept file and keeps nothing; 429, 503 and no connection keep the crashes, with what
    /// the file held, for the next start; a 200 takes out of the file what it carried.
    @Test func aPayloadOurSiteRefusesIsDroppedAndOneThatMayGoLaterIsKept() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("error-reports-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("error-reports.json")
        let older = crash(signal: 11, first: 1_763_200_000, last: 1_763_200_000), batch = [crash()]
        let both = ErrorReport.merged([older] + batch)
        let report = try #require(ErrorReport(fleet: Self.fleet, version: "0.1.285 (286)", system: nil, crashes: batch))
        func failure(_ channel: String, _ site: AnyClass = ErrorSite.self) async -> Error? {
            do { try await ErrorReportClient(protocolClasses: [site]).send(report, channel: channel); return nil } catch { return error }
        }
        for status in [400, 404, 413, 422] {
            try ErrorReport.keep([older], in: file)
            let error = try #require(await failure("https://status-\(status).platform.founderizer.com"))
            #expect(!ErrorReportError.keeps(error))
            #expect(ErrorReport.settle(batch, carriedKept: true, after: error, in: file).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
        // A refusal of a batch that did not carry the file leaves the file as it is.
        try ErrorReport.keep([older], in: file)
        #expect(ErrorReport.settle(batch, carriedKept: false, after: ErrorReportError.refused(400), in: file) == [older])
        #expect(ErrorReport.kept(file) == [older])
        for status in [429, 503, 500] {
            try ErrorReport.keep([older], in: file)
            let error = try #require(await failure("https://status-\(status).platform.founderizer.com"))
            #expect(ErrorReportError.keeps(error))
            #expect(ErrorReport.settle(batch, carriedKept: true, after: error, in: file) == both)
            #expect(ErrorReport.kept(file) == both)
        }
        try ErrorReport.keep([older], in: file)
        let lost = try #require(await failure("https://errors-lost.platform.founderizer.com", NoAnswer.self))
        #expect(lost is URLError && ErrorReportError.keeps(lost))
        #expect(ErrorReport.settle(batch, carriedKept: false, after: lost, in: file) == both)
        // A 200 that did not carry the file leaves it for the next start; one that carried it takes it away.
        #expect(await failure("https://errors-sent.platform.founderizer.com") == nil)
        #expect(ErrorReport.settle(batch, carriedKept: false, after: nil, in: file) == both)
        #expect(ErrorReport.settle(batch, carriedKept: true, after: nil, in: file).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // The rule, answer by answer: only 429, 5xx and no answer keep.
        for status in [0, 429, 500, 503, 599] { #expect(ErrorReportError.keeps(ErrorReportError.refused(status))) }
        for status in [201, 204, 307, 400, 401, 403, 404, 409, 413, 422, 499, 600] {
            #expect(!ErrorReportError.keeps(ErrorReportError.refused(status)), "\(status)")
        }
        #expect(ErrorReportError.keeps(ErrorReportError.unready) && ErrorReportError.keeps(ErrorReportError.badChannel))
        #expect(!ErrorReportError.keeps(ErrorReportError.tooLarge))
    }

    /// **The kept file never holds more than the contract's 20 entries**: each write merges what it is given and cuts it
    /// to the 20 seen last, and a read does the same with a file that holds more.
    @Test func theKeptFileNeverHoldsMoreThanTwentyEntries() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("error-reports-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("error-reports.json")
        func distinct(_ codes: Range<Int>) -> [ErrorReport.Crash] {
            codes.map { crash(code: $0, first: 1_763_300_000 + $0, last: 1_763_300_000 + $0) }
        }
        func entries() throws -> Int { (try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [Any])?.count ?? -1 }
        try ErrorReport.keep(distinct(0..<25), in: file)
        #expect(try entries() == 20)
        #expect(ErrorReport.kept(file).map(\.code) == (5..<25).map { Int?($0) })
        // Ten more after a send that can still go: still 20, the ones seen last.
        let held = ErrorReport.settle(distinct(25..<35), carriedKept: false, after: ErrorReportError.refused(503), in: file)
        #expect(held.map(\.code) == (15..<35).map { Int?($0) })
        #expect(try entries() == 20)
        // A file that holds more, written by another hand, is read as its 20 seen last.
        try JSONEncoder().encode(distinct(0..<30)).write(to: file)
        #expect(ErrorReport.kept(file).map(\.code) == (10..<30).map { Int?($0) })
    }

    @Test func thePrivacyPageIsInTheLanguageOfTheAppsWords() throws {
        let english = "https://platform.founderizer.com/privacy#error-reports"
        let spanish = "https://platform.founderizer.com/es/privacy#error-reports"
        for language in ["es", "es-MX", "es_ES"] { #expect(ErrorReport.privacy(language: language).absoluteString == spanish) }
        for other in ["en", "en-GB", "et", "est", nil] { #expect(ErrorReport.privacy(language: other).absoluteString == english) }
        // The page of the words that the app shows: English here, Spanish with the Spanish table.
        #expect(ErrorReport.privacyPage.absoluteString == english)
        let table = try LocalizedTests.table(["Privacy": "Privacidad"])
        defer { try? FileManager.default.removeItem(at: table.bundleURL.deletingLastPathComponent()) }
        Localized.$bundle.withValue(table) {
            #expect(ErrorReport.privacyPage.absoluteString == spanish)
        }
    }
}

/// **The Mac's day** (W17 of the reliability plan, inside the owner's yes Q3, and Q5): the `app` block, the copies of
/// our site's lists, and the sender's rules (`ErrorReportsSending`): when the day goes and on which answer of the switch.
/// The rules that matter most are about what must **not** go: a day after the owner turned the switch off or said no on
/// the first run, a day on another hub's answer or on one older than 7 days, an empty report, and any word of this Mac
/// that is not a word of our site's lists.
struct ErrorReportsDayTests {
    static let fleet = "0123456789abcdef"
    static let t0 = Date(timeIntervalSince1970: 1_763_300_000)
    static let hour: TimeInterval = 3600
    static let hub = "http://hub.example:8765/"

    /// A hub's releases reading: rows newest first, as `GET /ui/releases` gives them.
    static func releases(_ rows: [(version: String, state: String, applied: Bool, hold: Bool)] = [
        ("2026.11.762", "verified", false, false), ("2026.11.761", "held", false, true),
        ("2026.11.760", "done", true, false)], channel: String = "https://errors-day.platform.founderizer.com",
                         fleet: String? = fleet, words: String = "") -> ReleaseState {
        let rows = rows.enumerated().map { place, row in
            """
            {"id": \(100 - place), "revision": "\(String(repeating: "a", count: 40))", "version": "\(row.version)",
             "notes": "https://platform.founderizer.com/\(words)", "says": "\(words)", "hold": \(row.hold),
             "state": "\(row.state)", "reached": \(row.applied ? "\"\(String(repeating: "b", count: 40))\"" : "null"),
             "seen_at": 1763300000, "automatic": true, "applied": \(row.applied)}
            """
        }
        let body = """
        {"db": "g1", "time": 1763300000, "branch": "config\(words)", "channel": "\(channel)",
         "upstream": "https://github.com/example/fleet\(words).git", "automatic": true, "have_release_key": true,
         "idle": true, "open_tasks": [], "running": false, "last_check": {"at": null, "says": "\(words)", "status": 200},
         "entitlement": {"fleet": \(fleet.map { "\"\($0)\"" } ?? "null"), "channel_said": "\(words)"},
         "releases": [\(rows.joined(separator: ","))]}
        """
        return try! JSONDecoder().decode(ReleaseState.self, from: Data(body.utf8))
    }

    static func day(update: AppHealth.Update = .init(state: "current", cause: "none", tries: 0, newest: "0.1.500 (500)"),
                    reach: String = "none") -> AppHealth {
        AppHealth(update: update, hub: .init(reach: reach, hours: 0, runs: "2026.11.760", newest: "2026.11.762", missing: 1),
                  installs: [])
    }

    static func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// **The sender's rules with a hub and our site as stand-ins**: its own defaults, kept file and two clocks, the
    /// wall clock and the time awake (the uptime, which stops while the Mac sleeps). `switchOn` is the hub's answer to
    /// the switch's read (nil: the read fails); `whileReading` runs inside the reads of the switch and of the releases,
    /// as a press of the owner during them; `sent` holds each body that went, with its channel, before `answer` gives
    /// our site's answer.
    @MainActor final class Harness {
        let defaults: TestDefaults
        let folder: URL
        let clock: Clock
        private(set) var sending: ErrorReportsSending
        var switchOn: Bool? = true
        var reads = 0
        var releasesRead: ReleaseState? = ErrorReportsDayTests.releases()
        var storeReleases: ReleaseState?
        var sources: ErrorReportsSending.Sources
        var answer: (ErrorReport) throws -> Void = { _ in }
        var whileReading: (String) -> Void = { _ in }
        var sent: [(body: [String: Any], channel: String?)] = []

        final class Clock {
            var now: Date
            var awake: TimeInterval = 1000
            init(_ now: Date) { self.now = now }
        }

        init(_ label: String, at now: Date = ErrorReportsDayTests.t0) {
            defaults = TestDefaults(label)
            folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
            clock = Clock(now)
            sources = .init(update: AppUpdateFacts(at: now, in: defaults), running: AppVersion(name: "0.1.499", build: 499),
                            stops: [])
            sending = Self.sending(folder: folder, defaults: defaults, clock: clock)
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        private static func sending(folder: URL, defaults: UserDefaults, clock: Clock) -> ErrorReportsSending {
            ErrorReportsSending(file: folder.appendingPathComponent("error-reports.json"), version: "0.1.499 (499)",
                                system: "macOS 26.6.2", defaults: defaults, now: { clock.now }, uptime: { clock.awake })
        }

        /// The app starts again: a new sender on the same defaults and kept file.
        func restart() { sending = Self.sending(folder: folder, defaults: defaults, clock: clock) }

        /// The wall clock; a move forward is time awake too (`sleep` is not).
        var now: Date {
            get { clock.now }
            set {
                clock.awake += max(0, newValue.timeIntervalSince(clock.now))
                clock.now = newValue
            }
        }

        /// The Mac sleeps: the wall clock moves, the time awake does not.
        func sleep(_ seconds: TimeInterval) { clock.now += seconds }

        var file: URL { folder.appendingPathComponent("error-reports.json") }

        /// One tick of the store's loop, and the end of the attempt that it started. `answers`: the hub answers now.
        func tick(answers: Bool = true, reach: ReachFacts.ReadKind = .none, answered: Date? = nil,
                  hub: String = ErrorReportsDayTests.hub, offered: Bool = true) async {
            let calls = ErrorReportsSending.Calls(
                readSwitch: {
                    self.reads += 1
                    self.whileReading("switch")
                    guard let on = self.switchOn else { throw HubError.invalidResponse }
                    return on
                },
                readReleases: {
                    self.whileReading("releases")
                    return self.releasesRead
                },
                storeReleases: { self.storeReleases }, sources: { self.sources },
                send: { report, channel in
                    self.sent.append((try ErrorReportsDayTests.json(report.body()), channel))
                    try self.answer(report)
                })
            let tick = ErrorReportsSending.Tick(hub: hub, database: answers ? "g1" : nil, offered: offered,
                                                answered: answered ?? (answers ? now : nil), reach: reach)
            await sending.tick(tick, calls: calls)?.value
        }

        /// The hub is silent: a tick now and one after `ErrorReportsDay.patience`.
        func silent(reach: ReachFacts.ReadKind = .timedOut) async {
            await tick(answers: false, reach: reach)
            now += ErrorReportsDay.patience
            await tick(answers: false, reach: reach)
        }
    }

    // ------------------------------------------------------------ the switch

    /// **No day goes after the owner turned the switch off** (the plan's test of W17), through the sender's own rules.
    /// The hub answers "on", and the day goes. The owner turns it off (`off()`: the switch of Settings, a reading of Help,
    /// a hub that says off). Then the hub is silent for days: no day goes on the older "on". The hub answers again and
    /// says off: nothing; it says on again at the next look: the day goes.
    @MainActor @Test func noDayGoesAfterTheOwnerTurnedTheSwitchOff() async throws {
        let h = Harness("ErrorReportsDayOff")
        await h.tick()
        #expect(h.sent.count == 1 && h.reads == 1 && h.sent.first?.channel == "https://errors-day.platform.founderizer.com")
        let first = try #require(h.sent.first?.body)
        #expect(first["fleet"] as? String == Self.fleet && first["app"] != nil && first["crashes"] == nil)

        h.sending.off()
        for days in [1.0, 2, 6] {
            h.now = Self.t0 + days * ErrorReportsDay.day
            await h.silent()
        }
        #expect(h.sent.count == 1, "a day went after the switch was turned off")

        h.now = Self.t0 + 6 * ErrorReportsDay.day + 2 * Self.hour
        h.switchOn = false
        await h.tick()
        #expect(h.reads == 2 && h.sent.count == 1)
        h.now += 2 * Self.hour
        h.switchOn = true
        await h.tick()
        #expect(h.reads == 3 && h.sent.count == 2)
    }

    /// **A "no" on the first run's page stays "no"** (review A, finding 1): the owner said no, and the wait of that
    /// answer ended with no hub (Back to the welcome page, a new start of the app: `forget()`); the hub of the older
    /// "on" is silent: no day goes. **And no day goes while that "no" waits for a hub** (finding 2), also while the hub
    /// answers and its switch says on (a restore during the first run).
    @MainActor @Test func aFirstRunNoStaysNo() async throws {
        let h = Harness("ErrorReportsDayFirstRun")
        h.storeReleases = Self.releases()          // a look at the switch keeps the fleet's id, as in the app
        await h.tick()
        #expect(h.sent.count == 1)
        FirstRunReports.choose(false, in: h.defaults)
        FirstRunReports.forget(in: h.defaults)
        h.now += ErrorReportsDay.day
        await h.silent()
        #expect(h.sent.count == 1, "a day went on an older answer after a first-run no")

        FirstRunReports.choose(false, in: h.defaults)
        h.now += ErrorReportsDay.day
        await h.tick()
        #expect(h.reads == 2 && h.sent.count == 1, "a day went while a first-run no waits for the hub")
        // That wait ends with no receipt of a hub: the hub's "on" of that moment is no answer that a silent day goes on.
        FirstRunReports.forget(in: h.defaults)
        h.now += ErrorReportsDay.day
        await h.silent()
        #expect(h.sent.count == 1, "a day went on the hub's on that came while a first-run no waited")
        // The hub answers "on" with no "no" that waits: the day goes.
        h.now += 2 * Self.hour
        await h.tick()
        #expect(h.reads == 3 && h.sent.count == 2)
    }

    /// **The kept answer belongs to its hub, and goes with it** (review A, finding 3; review B, finding 1): another
    /// hub's answer counts for nothing; "Start again" (`StartAgain.forgetKept`) and a connect to another hub
    /// (`ErrorReportsDay.forget`) take the answer and the hub's last answer away, so no day goes for the fleet that the
    /// Mac left and no hours count from its hub.
    @MainActor @Test func theKeptAnswerBelongsToItsHubAndGoesWithIt() async throws {
        let h = Harness("ErrorReportsDayHub")
        await h.tick()
        #expect(h.sent.count == 1)
        h.now = Self.t0 + 23 * Self.hour
        await h.tick()                                     // the hourly look: the hub's answer "on" is new
        #expect(h.reads == 2 && h.sent.count == 1)
        h.now = Self.t0 + ErrorReportsDay.day
        await h.tick(answers: false, hub: "http://other.example:8765/")
        h.now += ErrorReportsDay.patience
        await h.tick(answers: false, hub: "http://other.example:8765/")
        #expect(h.sent.count == 1, "a day went on another hub's answer")
        await h.tick(answers: false)                       // the same hub: the day goes on its answer
        #expect(h.sent.count == 2 && (h.sent.last?.body["app"] as? [String: Any]) != nil)

        let at = h.now
        ErrorReportsDay.take(.on(Self.releases()), hub: Self.hub, now: at, in: h.defaults)
        ErrorReportsDay.noteHub(answered: at, in: h.defaults)
        StartAgain.forgetKept(hub: try #require(URL(string: Self.hub)), hubServerDeleted: false, in: h.defaults)
        #expect(ErrorReportsDay.lastAnswer(in: h.defaults) == nil && ErrorReportsDay.hubAnswered(now: at, in: h.defaults) == nil)
        ErrorReportsDay.take(.on(Self.releases()), hub: Self.hub, now: at, in: h.defaults)
        ErrorReportsDay.noteHub(answered: at, in: h.defaults)
        ErrorReportsDay.forget(in: h.defaults)
        #expect(ErrorReportsDay.take(.noAnswer, hub: Self.hub, now: at + Self.hour, in: h.defaults) == nil)
        #expect(ErrorReportsDay.hubAnswered(now: at, in: h.defaults) == nil)
    }

    /// **The last answer lasts one day, and only an answer "on" with a fleet's id counts** (Q5, the owner's answer of
    /// 22 November 2026). No answer at all sends nothing; an answer of a day goes and one a second older does not; an
    /// answer written while the clock was more than a day ahead does not count; a hub silent for less than `patience`
    /// of time awake is waited for; an answer "off" counts for nothing, also one that holds a fleet's id; a look at the
    /// switch with no releases reading keeps the fleet's id of the kept answer (review A round 2, N6).
    @Test func theLastAnswerLastsOneDayAndOnlyOnAnswerOn() throws {
        let defaults = TestDefaults("ErrorReportsDayOne")
        let lasts = ErrorReportsDay.lasts
        #expect(lasts == 86_400)
        #expect(ErrorReportsDay.take(.noAnswer, hub: Self.hub, now: Self.t0, in: defaults) == nil)
        #expect(ErrorReportsDay.lastAnswer(hub: Self.hub, silentFor: lasts, now: Self.t0, in: defaults) == nil)

        ErrorReportsDay.take(.on(Self.releases()), hub: Self.hub, now: Self.t0, in: defaults)
        #expect(ErrorReportsDay.take(.noAnswer, hub: Self.hub, now: Self.t0 + lasts, in: defaults)?.fleet == Self.fleet)
        #expect(ErrorReportsDay.take(.noAnswer, hub: Self.hub, now: Self.t0 + lasts + 1, in: defaults) == nil)
        #expect(ErrorReportsDay.take(.noAnswer, hub: nil, now: Self.t0, in: defaults) == nil)
        // A look with no releases reading: the fleet's id, the channel and the releases stay, with the new time.
        ErrorReportsDay.take(.on(nil), hub: Self.hub, now: Self.t0 + 2 * Self.hour, in: defaults)
        let looked = try #require(ErrorReportsDay.take(.noAnswer, hub: Self.hub, now: Self.t0 + lasts + Self.hour,
                                                       in: defaults))
        #expect(looked.fleet == Self.fleet && looked.channel == "https://errors-day.platform.founderizer.com")
        #expect(looked.releases?.runs == "2026.11.760" && looked.at == (Self.t0 + 2 * Self.hour).timeIntervalSince1970)
        let now = Self.t0 + Self.hour
        #expect(ErrorReportsDay.lastAnswer(hub: Self.hub, silentFor: nil, now: now, in: defaults) == nil)
        #expect(ErrorReportsDay.lastAnswer(hub: Self.hub, silentFor: ErrorReportsDay.patience - 1, now: now,
                                           in: defaults) == nil)
        #expect(ErrorReportsDay.lastAnswer(hub: Self.hub, silentFor: ErrorReportsDay.patience, now: now,
                                           in: defaults) != nil)
        // An answer of a clock that was more than a day ahead, and an answer with no fleet's id, count for nothing.
        ErrorReportsDay.take(.on(Self.releases()), hub: Self.hub, now: Self.t0 + 2 * ErrorReportsDay.day, in: defaults)
        #expect(ErrorReportsDay.take(.noAnswer, hub: Self.hub, now: Self.t0 + ErrorReportsDay.day - 1, in: defaults) == nil)
        ErrorReportsDay.take(.on(Self.releases(fleet: nil)), hub: Self.hub, now: Self.t0, in: defaults)
        #expect(ErrorReportsDay.take(.noAnswer, hub: Self.hub, now: now, in: defaults) == nil)
        ErrorReportsDay.take(.on(nil), hub: Self.hub, now: Self.t0, in: defaults)
        #expect(ErrorReportsDay.take(.noAnswer, hub: Self.hub, now: now, in: defaults) == nil)
        // Another hub's answer gives a look of this hub nothing to keep.
        ErrorReportsDay.take(.on(Self.releases()), hub: "http://other.example:8765/", now: Self.t0, in: defaults)
        ErrorReportsDay.take(.on(nil), hub: Self.hub, now: Self.t0, in: defaults)
        #expect(ErrorReportsDay.take(.noAnswer, hub: Self.hub, now: now, in: defaults) == nil)
        // An answer "off" that holds a fleet's id and the hub, as a later version may keep it.
        let off = #"{"send": false, "at": \#(Self.t0.timeIntervalSince1970), "hub": "\#(Self.hub)", "fleet": "\#(Self.fleet)"}"#
        defaults.set(Data(off.utf8), forKey: ErrorReportsDay.answerKey)
        #expect(ErrorReportsDay.lastAnswer(in: defaults)?.fleet == Self.fleet)
        #expect(ErrorReportsDay.take(.noAnswer, hub: Self.hub, now: now, in: defaults) == nil)
    }

    /// **No install from before the switch's "on" goes** (the second reader's M3 of F5 piece 4; the owner's claim 5 of
    /// the F5 analysis, "Nothing from before his yes goes", which the crashes keep): a stop while the switch is off,
    /// then "on": the day's block holds no install of it. A stop after the "on" is in the next day's block. A stop
    /// before an "off" and an "on" again is in none. The start is the first answer "on" of a run of answers "on" of
    /// one hub: an answer "off", a first-run "Don't send" and another hub's answer end the run.
    @MainActor @Test func noInstallFromBeforeTheSwitchsOnGoes() async throws {
        func stop(_ at: Date) -> InstallStop { InstallStop(kind: "server", stop: "timed_out", cause: "none", at: at) }
        func installs(_ sent: [String: Any]?) -> [Int] {
            ((sent?["app"] as? [String: Any])?["installs"] as? [[String: Any]] ?? []).compactMap { $0["last"] as? Int }
        }
        let h = Harness("ErrorReportsDayFloor")
        h.switchOn = false
        await h.tick()
        #expect(h.reads == 1 && h.sent.isEmpty)
        let whileOff = Self.t0 + Self.hour
        h.sources.stops = [stop(whileOff)]
        h.now = Self.t0 + 2 * Self.hour
        h.switchOn = true
        await h.tick()
        #expect(h.reads == 2 && h.sent.count == 1)
        #expect(installs(h.sent.last?.body) == [], "a stop from while the switch was off went")
        let afterOn = Self.t0 + 3 * Self.hour
        h.sources.stops.insert(stop(afterOn), at: 0)
        h.now = Self.t0 + 2 * Self.hour + ErrorReportsDay.day
        await h.tick()
        #expect(h.sent.count == 2 && installs(h.sent.last?.body) == [Int(afterOn.timeIntervalSince1970)])

        // A stop, then the switch off and on again: the next day holds none of it.
        let beforeOff = h.now + Self.hour - 60
        h.sources.stops.insert(stop(beforeOff), at: 0)
        h.now += Self.hour
        h.switchOn = false
        await h.tick()
        h.now += Self.hour
        h.switchOn = true
        await h.tick()
        #expect(h.reads == 5 && h.sent.count == 2)
        h.now = Self.t0 + 2 * Self.hour + 2 * ErrorReportsDay.day
        await h.tick()
        #expect(h.sent.count == 3 && installs(h.sent.last?.body) == [], "a stop from before an off went")

        // The run of answers "on", answer by answer.
        let defaults = TestDefaults("ErrorReportsDayFloorRun")
        ErrorReportsDay.take(.on(Self.releases()), hub: Self.hub, now: Self.t0, in: defaults)
        ErrorReportsDay.take(.on(nil), hub: Self.hub, now: Self.t0 + Self.hour, in: defaults)
        #expect(ErrorReportsDay.installsSince(now: Self.t0 + 2 * Self.hour, in: defaults) == Self.t0)
        FirstRunReports.choose(false, in: defaults)
        FirstRunReports.forget(in: defaults)
        ErrorReportsDay.take(.on(nil), hub: Self.hub, now: Self.t0 + 2 * Self.hour, in: defaults)
        #expect(ErrorReportsDay.installsSince(now: Self.t0 + 3 * Self.hour, in: defaults) == Self.t0 + 2 * Self.hour)
        ErrorReportsDay.take(.on(nil), hub: "http://other.example:8765/", now: Self.t0 + 3 * Self.hour, in: defaults)
        ErrorReportsDay.take(.on(nil), hub: Self.hub, now: Self.t0 + 4 * Self.hour, in: defaults)
        #expect(ErrorReportsDay.installsSince(now: Self.t0 + 5 * Self.hour, in: defaults) == Self.t0 + 4 * Self.hour)
    }

    /// **A press "on" that the hub took starts the run at the press** (the second reader's R2-M1 of F5 piece 4). In a
    /// first run the owner presses "Send" at P; the hub answers with its switch off, because the "Send" waits for the end
    /// of the first run; a join stops; the first run ends and the hub takes the "Send": the first report holds that stop,
    /// and not a stop from before P. A press "on" in Settings › Help with a stop in the next minutes: the stop goes in
    /// the next report, before this Mac's next hourly look, and a stop of while the switch was off does not.
    @MainActor @Test func aPressOnThatTheHubTookStartsTheRunAtThePress() async throws {
        func stop(_ at: Date) -> InstallStop { InstallStop(kind: "server", stop: "timed_out", cause: "none", at: at) }
        func installs(_ sent: [String: Any]?) -> [Int] {
            ((sent?["app"] as? [String: Any])?["installs"] as? [[String: Any]] ?? []).compactMap { $0["last"] as? Int }
        }
        let h = Harness("ErrorReportsDayPressFirstRun")
        let press = Self.t0
        h.sources.stops = [stop(press - 60)]
        FirstRunReports.choose(true, at: press, in: h.defaults)
        h.now = press + 600
        h.switchOn = false
        await h.tick()                                      // the hub answers, with its switch off
        #expect(h.reads == 1 && h.sent.isEmpty)
        let afterAnswer = h.now + 60
        h.sources.stops.insert(stop(afterAnswer), at: 0)
        h.now += 1200                                       // the first run ends, and the hub takes the "Send"
        #expect(await FirstRunReports.deliver(offered: true, in: h.defaults) { _ in })
        ErrorReportsDay.pressedOn(hub: Self.hub, at: try #require(FirstRunReports.pressed(in: h.defaults)), now: h.now,
                                  in: h.defaults)
        h.switchOn = true
        h.now += 60
        await h.tick()
        #expect(h.reads == 2 && h.sent.count == 1, "no report went after the hub took the first run's Send")
        #expect(installs(h.sent.last?.body) == [Int(afterAnswer.timeIntervalSince1970)],
                "a stop of the first run after its hub answered was lost, or one from before the press went")

        let s = Harness("ErrorReportsDayPressSettings")
        s.switchOn = false
        await s.tick()                                      // the switch is off
        let pressedAt = Self.t0 + 600
        s.now = pressedAt + 30
        ErrorReportsDay.pressedOn(hub: Self.hub, at: pressedAt, now: s.now, in: s.defaults)
        s.switchOn = true
        let soon = pressedAt + 120
        s.sources.stops = [stop(soon), stop(Self.t0 + 60)]
        s.now = pressedAt + 180
        await s.tick()
        #expect(s.sent.count == 1 && installs(s.sent.last?.body) == [Int(soon.timeIntervalSince1970)],
                "a stop in the minutes after a press on in Settings was lost")
    }

    /// **While the hub answers, the day goes only on a new read of the switch** (review A, finding 4): a read that
    /// fails sends nothing on the kept answer and moves the day by an hour; a switch that read off is not asked again
    /// for the day before the hourly look.
    @MainActor @Test func whileTheHubAnswersTheDayWaitsForANewReadOfTheSwitch() async throws {
        let h = Harness("ErrorReportsDayRead")
        await h.tick()
        #expect(h.sent.count == 1 && h.reads == 1)
        h.now += ErrorReportsDay.day
        h.switchOn = nil
        await h.tick()
        #expect(h.reads == 2 && h.sent.count == 1)
        for minutes in [2.0, 30, 59] {       // the hub answers: no day on the kept answer, no read before the hour
            h.now = Self.t0 + ErrorReportsDay.day + minutes * 60
            await h.tick()
        }
        #expect(h.reads == 2 && h.sent.count == 1)
        h.now = Self.t0 + ErrorReportsDay.day + Self.hour
        h.switchOn = true
        await h.tick()
        #expect(h.reads == 3 && h.sent.count == 2)

        // The switch reads off at the look a day later; the day is due, and the hub is not asked again before the next
        // hourly look.
        h.switchOn = false
        h.now += ErrorReportsDay.day
        await h.tick()
        #expect(h.reads == 4 && h.sent.count == 2)
        let off = h.now
        for minutes in [1.0, 30, 59] {
            h.now = off + minutes * 60
            await h.tick()
        }
        #expect(h.reads == 4 && h.sent.count == 2)
    }

    // ------------------------------------------------------------ the send

    /// **Our site refuses the day: the same report goes again at once without it when it has crashes, and the day comes
    /// again a day later** (the contract's "The health of a fleet"). The crash that rode with the day goes in the second
    /// send; a day alone goes no more (no empty report); the installs' start does not move for a report that went
    /// without the day; a 503 tries again in an hour; a 200 with the day moves the installs' start.
    @Test func aRefusedDayGoesAgainAtOnceWithoutItAndComesBackADayLater() async throws {
        let defaults = TestDefaults("ErrorReportsDayResend")
        let crash = ErrorReport.Crash(signal: 11, type: 1, code: 0, frames: [.lib], first: 1_763_300_000, last: 1_763_300_000)
        let report = try #require(ErrorReport(fleet: Self.fleet, version: "0.1.499 (499)", system: "macOS 26.6.2",
                                              crashes: [crash], app: Self.day()))
        var bodies: [[String: Any]] = []
        let failure = await ErrorReportsDay.deliver(report, day: true, at: Self.t0, in: defaults) { sent in
            bodies.append(try Self.json(sent.body()))
            if sent.app != nil { throw ErrorReportError.refused(400) }
        }
        #expect(failure == nil)
        #expect(bodies.count == 2 && bodies[0]["app"] != nil && bodies[1]["app"] == nil)
        #expect((bodies[1]["crashes"] as? [Any])?.count == 1)
        #expect(ErrorReportsDay.installsSince(now: Self.t0, in: defaults) == Self.t0 - ErrorReportsDay.day)
        #expect(!ErrorReportsDay.due(now: Self.t0 + ErrorReportsDay.day - 1, in: defaults))
        #expect(ErrorReportsDay.due(now: Self.t0 + ErrorReportsDay.day, in: defaults))

        // The switch went off during the first send: nothing goes again.
        bodies = []
        await ErrorReportsDay.deliver(report, day: true, at: Self.t0, in: defaults, stillOn: { false }) { sent in
            bodies.append(try Self.json(sent.body()))
            throw ErrorReportError.refused(400)
        }
        #expect(bodies.count == 1)

        // A day alone that our site refuses: one send, no empty report after it, and the day is the day's.
        let alone = try #require(ErrorReport(fleet: Self.fleet, version: "0.1.499 (499)", system: nil, crashes: [],
                                             app: Self.day()))
        let t1 = Self.t0 + 2 * ErrorReportsDay.day
        bodies = []
        let refused = await ErrorReportsDay.deliver(alone, day: true, at: t1, in: defaults) { sent in
            bodies.append(try Self.json(sent.body()))
            throw ErrorReportError.refused(400)
        }
        #expect(refused as? ErrorReportError == .refused(400))
        #expect(bodies.count == 1 && bodies[0]["app"] != nil)
        #expect(!ErrorReportsDay.due(now: t1 + Self.hour, in: defaults))

        // A 503 waits an hour, not a day; a 200 with the day moves the installs' start.
        let t2 = t1 + ErrorReportsDay.day
        await ErrorReportsDay.deliver(alone, day: true, at: t2, in: defaults) { _ in throw ErrorReportError.refused(503) }
        #expect(!ErrorReportsDay.due(now: t2 + Self.hour - 1, in: defaults))
        #expect(ErrorReportsDay.due(now: t2 + Self.hour, in: defaults))
        let taken = await ErrorReportsDay.deliver(alone, day: true, at: t2 + Self.hour, in: defaults) { _ in }
        #expect(taken == nil)
        #expect(ErrorReportsDay.installsSince(now: t2 + 2 * Self.hour, in: defaults) == t2 + Self.hour)
        #expect(!ErrorReportsDay.due(now: t2 + 2 * Self.hour, in: defaults))
    }

    /// **The crashes go as before W17** (review A, finding 7): with the hub's own releases read of the attempt, or
    /// not at all. When that read fails, they wait in the kept file for the next start, and the day goes alone on the
    /// store's reading of the same generation. At the next start, the crashes go with the hub's read, with no day.
    @MainActor @Test func theCrashesGoAsBeforeAndTheStoresReadingServesTheDayAlone() async throws {
        let h = Harness("ErrorReportsDayCrashes")
        h.releasesRead = nil
        h.storeReleases = Self.releases()
        h.sending.take([ErrorReport.Crash(signal: 11, type: 1, code: 0, frames: [.lib], first: 1_763_300_000,
                                          last: 1_763_300_000)])
        await h.tick()
        #expect(h.sent.count == 1 && h.sent[0].body["crashes"] == nil && h.sent[0].body["app"] != nil)
        #expect(ErrorReport.kept(h.file).count == 1)
        h.restart()
        h.releasesRead = Self.releases()
        h.now += Self.hour
        await h.tick()
        #expect(h.sent.count == 2 && (h.sent[1].body["crashes"] as? [Any])?.count == 1 && h.sent[1].body["app"] == nil)
        #expect(ErrorReport.kept(h.file).isEmpty)
    }

    /// **The hours count across starts, and the reach is the hub's own** (review B, findings 4 and 7): a day that
    /// goes while the hub answers says "none" and 0, also after a read that failed a moment before; after a start of
    /// the app, a day whose hub is silent counts its hours from the hub's last answer of the start before.
    @MainActor @Test func theHoursCountAcrossStartsAndTheReachIsTheHubsOwn() async throws {
        let h = Harness("ErrorReportsDayHours")
        await h.tick(reach: .timedOut)
        let hub = try #require((h.sent.first?.body["app"] as? [String: Any])?["hub"] as? [String: Any])
        #expect(hub["reach"] as? String == "none" && hub["hours"] as? Int == 0)
        // The hourly look at 20 hours; the hub answers the state half an hour later (no read of the switch then): its
        // newest answer, newer than the switch's.
        h.now = Self.t0 + 20 * Self.hour
        await h.tick()
        h.now += Self.hour / 2
        await h.tick()
        #expect(h.reads == 2 && h.sent.count == 1)
        h.restart()
        h.now = Self.t0 + 30 * Self.hour
        await h.silent(reach: .hostNotFound)
        let later = try #require((h.sent.last?.body["app"] as? [String: Any])?["hub"] as? [String: Any])
        // 9 whole hours and three quarters since the hub's last answer.
        #expect(h.sent.count == 2 && later["reach"] as? String == "host_not_found" && later["hours"] as? Int == 9)
        #expect(later["runs"] as? String == "2026.11.760" && later["newest"] as? String == "2026.11.762")
    }

    /// The day's report has the contract's keys and nothing else: every key of the block is there, a version that it
    /// does not know goes as `null`, and a day with no crash has no `crashes`.
    @Test func theDayHasTheContractsKeysAndNothingElse() throws {
        let health = AppHealth(update: .init(state: "none", cause: "none", tries: 0, newest: nil),
                               hub: .init(reach: "none", hours: 9, runs: nil, newest: nil, missing: 0),
                               installs: [.init(kind: "server", stop: "installer_stopped", cause: "firewall", count: 2,
                                                first: 1_763_300_000, last: 1_763_390_000)])
        let report = try #require(ErrorReport(fleet: Self.fleet, version: "0.1.499 (499)", system: "macOS 26.6.2",
                                              crashes: [], app: health))
        let body = try Self.json(report.body())
        #expect(Set(body.keys) == ["fleet", "from", "version", "system", "app"])
        let app = try #require(body["app"] as? [String: Any])
        #expect(Set(app.keys) == ["update", "hub", "installs"])
        let update = try #require(app["update"] as? [String: Any]), hub = try #require(app["hub"] as? [String: Any])
        #expect(Set(update.keys) == ["state", "cause", "tries", "newest"] && update["newest"] is NSNull)
        #expect(Set(hub.keys) == ["reach", "hours", "runs", "newest", "missing"] && hub["runs"] is NSNull)
        #expect(hub["hours"] as? Int == 0)       // 0 with "none"
        let install = try #require((app["installs"] as? [[String: Any]])?.first)
        #expect(Set(install.keys) == ["kind", "stop", "cause", "count", "first", "last"])
        #expect(ErrorReport(fleet: Self.fleet, version: "0.1.499 (499)", system: nil, crashes: [], app: nil) == nil)
    }

    // ------------------------------------------------------------ the words

    /// **Each copy is our site's list (founderizer-web, src/lib/errors.ts, HEALTH_WORDS of 21 November 2026), word for
    /// word.** A word comes to our site first, and only then into a copy and here: a Mac whose copy took a word that
    /// our site does not have would have each day refused.
    @Test func eachCopyIsOurSitesListAsItIsToday() {
        let theirs = [
            "updateState": "current waiting failed refused held none other",
            "updateCause": "none dns connect tls http timeout disk manifest translocated read_only size checksum "
                + "cannot_unpack not_one_app unreadable_bundle not_founderizer mismatch unsigned wrong_signature "
                + "cannot_replace other",
            "reach": "none invalid_address refused_this_mac not_a_hub hub_error refused unreadable timed_out "
                + "no_connection host_not_found no_network blocked_by_app not_secure other",
            "installKind": "hub server mac other",
            "installStop": "none cannot_start installer_stopped server_unreached login_refused step_failed hub_not_ours "
                + "not_root timed_out no_claim_code no_checklist check_stopped needs_sudo_password needs_ssh_password "
                + "network_key_refused hub_refused hub_unreached mac_refused mac_unreachable mac_unreadable other",
            "installCause": "none needs_root system_not_supported no_systemd hub_no_answer code_not_fetched "
                + "join_code_refused join_code_expired server_name_refused server_name_unread hub_busy private_network "
                + "firewall agent_users vault updates packages service hub_claim agent_program homebrew wrong_mac_user "
                + "other",
        ]
        let copies = ["updateState": AppHealth.updateStates, "updateCause": AppHealth.updateCauses,
                      "reach": AppHealth.reaches, "installKind": AppHealth.installKinds,
                      "installStop": AppHealth.installStops, "installCause": AppHealth.installCauses]
        for (name, copy) in copies {
            #expect(copy == theirs[name]?.split(separator: " ").map(String.init), "\(name): put a new word on our side first")
        }
    }

    /// **Each word of this app's own sources is in its copy**: a new kind of failed read, a new stop or cause of an
    /// install, or a new failure of the update reaches our site's lists, and so these copies, before a release sends
    /// it; else it goes as "other", and nobody on our side reads what broke.
    @Test func eachWordOfTheAppsSourcesIsInItsCopy() {
        #expect(ReachFacts.ReadKind.allCases.map(\.rawValue).filter { !AppHealth.reaches.contains($0) } == [])
        #expect(InstallRecord.Stop.allCases.map(\.rawValue).filter { !AppHealth.installStops.contains($0) } == [])
        #expect(InstallCause.allCases.map(\.rawValue).filter { !AppHealth.installCauses.contains($0) } == [])
        let kinds = InstallRecord.Kind.allCases.map { kind in
            var log = InstallLog(kind: kind, hub: nil, host: "192.0.2.1", at: Self.t0)
            log.stop(.other, says: nil, at: Self.t0)
            return InstallStop.of([log.record]).first?.kind ?? "missing"
        }
        #expect(kinds == ["hub", "server", "mac"])
        let failures: [AppUpdateFailure] = [
            .manifest, .translocated, .readOnly("/Applications"), .download(503), .size, .checksum, .cannotUnpack("x"),
            .notOneApp(2), .unreadableBundle, .notFounderizer("x"), .mismatch(said: "a", found: "b"), .unsigned,
            .wrongSignature(-67050), .cannotReplace("x"),
        ]
        // Each failure has a word of its own: none is "other" or "none", and no two share one.
        let words = failures.map { AppHealth.updateCause($0) }
        #expect(words.filter { !AppHealth.updateCauses.contains($0) || $0 == "other" || $0 == "none" } == [])
        #expect(Set(words).count == failures.count)
        for copy in [AppHealth.updateStates, AppHealth.updateCauses, AppHealth.reaches, AppHealth.installKinds,
                     AppHealth.installStops, AppHealth.installCauses] {
            #expect(copy.last == "other" && Set(copy).count == copy.count)
        }
    }

    /// **A canary in each source never rides in a value**: the words of the channel's answer and of a failed install,
    /// a build's name that is no version, the hub's releases (a version with a word, notes, lines), an error of the
    /// hub's read with an address, and an install's hub, host, server and line. The block holds only words of the lists,
    /// versions, whole numbers and times.
    @Test func aCanaryInEachSourceNeverRidesInAValue() throws {
        let defaults = TestDefaults("ErrorReportsDayCanary")
        let canary = "canary7f3"
        let manifest = AppManifest(version: "0.1 \(canary)", build: 500, url: "https://founderizer.com/\(canary).zip",
                                   sha256: String(repeating: "0", count: 64), size: 1, minimumSystem: nil,
                                   notes: "https://founderizer.com/\(canary)", hold: false, signature: canary)
        var facts = AppUpdateFacts(at: Self.t0, in: defaults)
        facts.read(AppUpdateReading(status: 200, says: canary, manifest: manifest, offered: true), at: Self.t0, in: defaults)
        facts.read(AppUpdateReading(status: 0, says: canary, unreachable: true, urlError: URLError.cannotFindHost.rawValue),
                   at: Self.t0, in: defaults)
        AppUpdateTries.failed(build: 500, error: AppUpdateFailure.cannotReplace(canary), in: defaults)
        AppUpdateTries.failed(build: 500, error: AppUpdateFailure.readOnly("/Users/\(canary)"), in: defaults)
        let update = AppHealth.update(facts, tries: AppUpdateTries.kept(in: defaults),
                                      running: AppVersion(name: canary, build: 499), now: Self.t0)
        #expect(update == .init(state: "failed", cause: "read_only", tries: 2, newest: nil))

        let state = Self.releases([("2026.11.763-\(canary)", "verified", false, false), ("2026.11.760", "done", true, false)],
                                  channel: "https://\(canary).founderizer.com", words: canary)
        let failed = URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: "http://\(canary).example:8765/"])
        let hub = AppHealth.hub(reach: ReachFacts.readKind(failed), answered: Self.t0 - 30 * Self.hour,
                                releases: .init(state), now: Self.t0)
        #expect(hub == .init(reach: "timed_out", hours: 30, runs: "2026.11.760", newest: nil, missing: 1))

        var log = InstallLog(kind: .join, hub: "http://\(canary).example:8765/", host: "\(canary).example", at: Self.t0)
        log.place(server: "\(canary)-server")
        log.hide([canary])
        log.note(step: "join", state: .failed, at: Self.t0 + 60)
        log.stop(.installerStopped, says: "the \(canary) line", cause: .firewall, at: Self.t0 + 60)
        let installs = AppHealth.installs(InstallStop.of([log.record]), since: Self.t0)
        #expect(installs == [.init(kind: "server", stop: "installer_stopped", cause: "firewall", count: 1,
                                   first: 1_763_300_060, last: 1_763_300_060)])

        let report = try #require(ErrorReport(fleet: Self.fleet, version: "0.1.499 (499)", system: "macOS 26.6.2",
                                              crashes: [], app: AppHealth(update: update, hub: hub, installs: installs)))
        let sent = String(decoding: try report.body(), as: UTF8.self)
        #expect(!sent.lowercased().contains(canary), "\(sent)")
        // The kept answer keeps the channel for the send, and its releases only as versions of the contract.
        ErrorReportsDay.take(.on(state), hub: Self.hub, now: Self.t0, in: defaults)
        let kept = try #require(ErrorReportsDay.take(.noAnswer, hub: Self.hub, now: Self.t0 + Self.hour, in: defaults))
        #expect(kept.releases?.newest == nil && kept.releases?.runs == "2026.11.760")
    }

    // ------------------------------------------------------------ the facts

    /// **The update block says what the app's update came to** (the contract's UPDATE_STATE and UPDATE_CAUSE, agreed
    /// with the Release area): the state of the last read that reached the channel; a failed install of the newest
    /// build with its cause and tries, which a newer build or the build that runs ends; reads that fail for a day with
    /// the network's word; a download's or the channel's status as "http".
    @Test func theUpdateBlockSaysWhatTheAppsUpdateCameTo() {
        let defaults = TestDefaults("ErrorReportsDayUpdate")
        let running = AppVersion(name: "0.1.499", build: 499)
        func manifest(_ build: Int, hold: Bool = false) -> AppManifest {
            AppManifest(version: "0.1.\(build)", build: build, url: "https://founderizer.com/a.zip",
                        sha256: String(repeating: "0", count: 64), size: 1, minimumSystem: nil, notes: nil, hold: hold,
                        signature: "s")
        }
        /// The readings one `every` apart from `t0`, then the block at `now`.
        func update(_ readings: [AppUpdateReading], tries: AppUpdateTries? = nil, every: TimeInterval = 0,
                    at now: Date = Self.t0) -> AppHealth.Update {
            defaults.removeObject(forKey: AppUpdateFacts.failingKey)
            var facts = AppUpdateFacts(at: Self.t0, in: defaults)
            for (place, reading) in readings.enumerated() {
                facts.read(reading, at: Self.t0 + Double(place) * every, in: defaults)
            }
            return AppHealth.update(facts, tries: tries, running: running, now: now)
        }
        let offered = AppUpdateReading(status: 200, says: "", manifest: manifest(500), offered: true)
        #expect(update([]) == .init(state: "none", cause: "none", tries: 0, newest: nil))
        #expect(update([offered]) == .init(state: "waiting", cause: "none", tries: 0, newest: "0.1.500 (500)"))
        #expect(update([.init(status: 200, says: "", manifest: manifest(499), current: true)]).state == "current")
        #expect(update([.init(status: 200, says: "", manifest: manifest(500, hold: true))]).state == "held")
        #expect(update([.init(status: 200, says: "", manifest: manifest(500))]).state == "waiting")   // a newer macOS
        #expect(update([.init(status: 402, says: "", refused: true)]) == .init(state: "refused", cause: "http", tries: 0,
                                                                                newest: nil))
        #expect(update([.init(status: 200, says: "")]).cause == "manifest")
        #expect(update([.init(status: 404, says: "")]) == .init(state: "failed", cause: "http", tries: 0, newest: nil))

        // A failed install of the newest build; one that a newer build or the running build passed is no try now.
        let tried = AppUpdateTries(build: 500, tries: 3, cause: "translocated")
        #expect(update([offered], tries: tried) == .init(state: "failed", cause: "translocated", tries: 3,
                                                         newest: "0.1.500 (500)"))
        #expect(update([.init(status: 200, says: "", manifest: manifest(501), offered: true)], tries: tried).state == "waiting")
        #expect(update([.init(status: 200, says: "", manifest: manifest(499), current: true)],
                       tries: AppUpdateTries(build: 499, tries: 1, cause: "size")).state == "current")

        // Reads each hour that fail: the last state stands for a day, then the network's word.
        let lost = AppUpdateReading(status: 0, says: "", unreachable: true, urlError: URLError.cannotFindHost.rawValue)
        let day = [offered] + Array(repeating: lost, count: 25)
        #expect(update(day, every: Self.hour, at: Self.t0 + 25 * Self.hour - 1).state == "waiting")
        #expect(update(day, every: Self.hour, at: Self.t0 + 25 * Self.hour)
            == .init(state: "failed", cause: "dns", tries: 0, newest: "0.1.500 (500)"))
        let busy = AppUpdateReading(status: 503, says: "", unreachable: true)
        #expect(update(Array(repeating: busy, count: 25), every: Self.hour, at: Self.t0 + AppUpdatePolicy.long)
            == .init(state: "failed", cause: "http", tries: 0, newest: nil))
        // An install's errors by their words, a download's status as "http".
        #expect(AppHealth.updateCause(AppUpdateFailure.download(503)) == "http")
        #expect(AppHealth.updateCause(URLError(.timedOut)) == "timeout")
        #expect(AppHealth.updateCause(URLError(.secureConnectionFailed)) == "tls")
        #expect(AppHealth.updateCause(CancellationError()) == "other")
    }

    /// **The update says "failed" only for reads that fail now** (review B round 1, finding 2; review A round 2, N2;
    /// review B round 2, A): one failed read and a day with no read is no failure (the hub was silent, the Mac slept);
    /// reads through a day that fail are, also across a start of the app, with the cause word of the last one before
    /// any read of the new start; reads that stopped an hour ago are no failure now; a read that reaches the channel
    /// ends it.
    @Test func theUpdateSaysFailedOnlyForReadsThatFailNow() {
        let defaults = TestDefaults("ErrorReportsDayFailing")
        let lost = AppUpdateReading(status: 0, says: "", unreachable: true, urlError: URLError.timedOut.rawValue)
        let day = AppUpdatePolicy.long
        var once = AppUpdateFacts(at: Self.t0, in: defaults)
        once.read(lost, at: Self.t0, in: defaults)
        #expect(AppHealth.update(once, tries: nil, running: nil, now: Self.t0 + day).state == "none")
        #expect(AppHealth.update(once, tries: nil, running: nil, now: Self.t0 + 2 * day).state == "none")

        // Reads each hour, through the day, with a start of the app in between.
        for hour in 1...19 { once.read(lost, at: Self.t0 + Double(hour) * Self.hour, in: defaults) }
        var second = AppUpdateFacts(at: Self.t0 + 20 * Self.hour, in: defaults)     // the app started again
        for hour in 20...23 { second.read(lost, at: Self.t0 + Double(hour) * Self.hour, in: defaults) }
        let failed = AppHealth.Update(state: "failed", cause: "timeout", tries: 0, newest: nil)
        #expect(AppHealth.update(second, tries: nil, running: nil, now: Self.t0 + day) == failed)
        // A start after that, before its first read: the kept cause word, not "other".
        let third = AppUpdateFacts(at: Self.t0 + day, in: defaults)
        #expect(AppHealth.update(third, tries: nil, running: nil, now: Self.t0 + day) == failed)
        // The reads stopped (the hub went silent): an hour after the last one, no failure is said.
        #expect(AppHealth.update(third, tries: nil, running: nil, now: Self.t0 + 23 * Self.hour + ErrorReportsDay.retry)
            == failed)
        #expect(AppHealth.update(third, tries: nil, running: nil,
                                 now: Self.t0 + 23 * Self.hour + ErrorReportsDay.retry + 1).state == "none")
        var fourth = third
        fourth.read(AppUpdateReading(status: 200, says: "", current: true), at: Self.t0 + 25 * Self.hour, in: defaults)
        #expect(AppUpdateFacts(at: Self.t0 + 26 * Self.hour, in: defaults).failing == nil)
    }

    /// **A sleep of the Mac is no silence of the hub** (review A round 2, N1): the hub was silent a minute when the
    /// lid closed, and the Mac wakes 9 hours later with 10 seconds more of time awake: no day goes on the kept answer.
    /// After 15 minutes awake with no answer of the hub, it goes.
    @MainActor @Test func aSleepIsNoSilenceOfTheHub() async throws {
        let h = Harness("ErrorReportsDaySleep")
        await h.tick()
        h.now = Self.t0 + 20 * Self.hour
        await h.tick()                                      // the hourly look keeps the answer new
        #expect(h.reads == 2 && h.sent.count == 1)
        h.now += 60
        await h.tick(answers: false)
        h.sleep(9 * Self.hour)
        h.clock.awake += 10
        await h.tick(answers: false)
        #expect(h.sent.count == 1, "a sleep counted as the hub's silence")
        h.now += ErrorReportsDay.patience
        await h.tick(answers: false)
        #expect(h.sent.count == 2)
    }

    /// **The silence starts again at each answer of the hub** (review A round 2, N5): silent before the day is due,
    /// an answer 14 minutes later, silent again a minute after that as the day comes due: no day goes after two
    /// minutes of silence.
    @MainActor @Test func theSilenceStartsAgainAtEachAnswerOfTheHub() async throws {
        let h = Harness("ErrorReportsDaySilence")
        await h.tick()
        h.now = Self.t0 + 20 * Self.hour
        await h.tick()
        h.now = Self.t0 + ErrorReportsDay.day - 15 * 60
        await h.tick(answers: false)
        h.now += 14 * 60
        await h.tick()                                      // the hub answers (a look: no day is due yet)
        #expect(h.reads == 3 && h.sent.count == 1)
        h.now += 60                                         // the day is due
        await h.tick(answers: false)
        h.now += 60
        await h.tick(answers: false)
        #expect(h.sent.count == 1, "a day went after two minutes of silence")
    }

    /// **A switch-off during an attempt stops it** (review A round 2, N5): off during the read of the releases sends
    /// nothing and keeps no "on"; off during a send that our site refused with a 400 sends nothing again.
    @MainActor @Test func aSwitchOffDuringAnAttemptStopsIt() async throws {
        let h = Harness("ErrorReportsDayDuring")
        h.whileReading = { if $0 == "releases" { h.sending.off() } }
        await h.tick()
        #expect(h.reads == 1 && h.sent.isEmpty && ErrorReportsDay.lastAnswer(in: h.defaults)?.send == false)
        h.whileReading = { _ in }
        h.sending.take([ErrorReport.Crash(signal: 11, type: 1, code: 0, frames: [.lib], first: 1_763_300_000,
                                          last: 1_763_300_000)])
        h.answer = { _ in
            h.sending.off()
            throw ErrorReportError.refused(400)
        }
        h.now += 2 * Self.hour
        await h.tick()
        #expect(h.sent.count == 1 && h.sent[0].body["app"] != nil && h.sent[0].body["crashes"] != nil)
        #expect(ErrorReport.kept(h.file).isEmpty)
    }

    /// **A hub with no switch is a switch that is off** (review A round 2, N5): after it, no day goes on an older "on"
    /// while the hub does not answer.
    @MainActor @Test func aHubWithNoSwitchIsOff() async throws {
        let h = Harness("ErrorReportsDayNoSwitch")
        await h.tick()
        h.now = Self.t0 + 10 * Self.hour
        await h.tick()                                      // a look: the answer "on" of 10 hours is new
        h.now = Self.t0 + 20 * Self.hour
        await h.tick(offered: false)
        #expect(h.reads == 2 && ErrorReportsDay.lastAnswer(in: h.defaults)?.send == false)
        h.now = Self.t0 + ErrorReportsDay.day
        await h.silent()
        #expect(h.sent.count == 1, "a day went after a hub with no switch")
    }

    /// **A "no" on the first run's page during an attempt stops that attempt's day** (review A round 2, N4): the owner
    /// presses "Don't send" while the read of the switch runs; the hub says "on", and nothing goes.
    @MainActor @Test func aFirstRunNoDuringAnAttemptStopsItsDay() async throws {
        let h = Harness("ErrorReportsDayNoDuring")
        h.whileReading = { if $0 == "switch" { FirstRunReports.choose(false, in: h.defaults) } }
        await h.tick()
        #expect(h.reads == 1 && h.sent.isEmpty, "a day went after a first-run no during its attempt")
        #expect(ErrorReportsDay.lastAnswer(in: h.defaults)?.send == false)
    }

    /// **Kept crashes go again an hour later, with no new start** (the F5 analysis, piece 5): a send that fails with
    /// 503 keeps the crash; a minute later only the switch is read; an hour after the try, one more request holds the
    /// same crash, and the file goes after its 200. Before, an app that stayed open for weeks never sent it again.
    @MainActor @Test func keptCrashesGoAgainAnHourLaterWithNoNewStart() async throws {
        let h = Harness("ErrorReportsDayRetry")
        await h.tick()
        let crash = ErrorReport.Crash(signal: 11, type: 1, code: 0, frames: [.lib], first: 1_763_300_000,
                                      last: 1_763_300_000)
        h.sending.take([crash])
        h.answer = { _ in throw ErrorReportError.refused(503) }
        h.now += 60
        let tried = h.now
        await h.tick()
        #expect(h.sent.count == 2 && ErrorReport.kept(h.file) == [crash])
        h.answer = { _ in }
        h.now += 60
        await h.tick()
        #expect(h.sent.count == 2 && h.reads == 3)
        h.now = tried + ErrorReportsDay.retry
        await h.tick()
        #expect(h.sent.count == 3 && (h.sent.last?.body["crashes"] as? [Any])?.count == 1)
        #expect(ErrorReport.kept(h.file).isEmpty)
    }

    /// **A press "off" in Settings that got no answer keeps "off"** (review A round 2, N3): the hub may have taken
    /// it. A refusal is the hub's answer, and a press "on" changes nothing here.
    @Test func aPressOffThatGotNoAnswerKeepsOff() {
        #expect(ErrorReportsDay.pressKeepsOff(false, after: URLError(.timedOut)))
        #expect(ErrorReportsDay.pressKeepsOff(false, after: HubError.unavailable))
        #expect(ErrorReportsDay.pressKeepsOff(false, after: HubError.invalidResponse))
        #expect(!ErrorReportsDay.pressKeepsOff(false, after: HubError.refusal(HubRefusal(status: 409, hubWords: "no"))))
        #expect(!ErrorReportsDay.pressKeepsOff(true, after: URLError(.timedOut)))
    }

    /// **The hub and the installs say what this Mac kept**: the release that the hub runs, the newest of its channel,
    /// and the releases above the one it runs that are not held; whole hours since its last answer, 0 while it
    /// answers; and each kind of stop since the last day that our site took, counted, at most 10, a join as "server".
    @Test func theHubAndTheInstallsSayWhatTheMacKept() throws {
        let kept = AppHealth.HubReleases(Self.releases())
        #expect(kept == .init(runs: "2026.11.760", newest: "2026.11.762", missing: 1))
        #expect(AppHealth.HubReleases(Self.releases([("2026.11.762", "verified", false, false)])).missing == 1)
        #expect(AppHealth.hub(reach: .none, answered: Self.t0 - 90 * Self.hour, releases: kept, now: Self.t0).hours == 0)
        let lost = AppHealth.hub(reach: .hostNotFound, answered: Self.t0 - 90 * Self.hour - 1, releases: kept, now: Self.t0)
        #expect(lost == .init(reach: "host_not_found", hours: 90, runs: "2026.11.760", newest: "2026.11.762", missing: 1))

        func stop(_ kind: String, _ stop: String, _ cause: String = "none", _ seconds: TimeInterval) -> InstallStop {
            InstallStop(kind: kind, stop: stop, cause: cause, at: Self.t0 + seconds)
        }
        let stops = [stop("server", "installer_stopped", "firewall", 10), stop("server", "installer_stopped", "firewall", 30),
                     stop("hub", "server_unreached", "firewall", 20), stop("server", "timed_out", "", -5)]
        #expect(AppHealth.installs(stops, since: Self.t0) == [
            .init(kind: "server", stop: "installer_stopped", cause: "firewall", count: 2, first: 1_763_300_010,
                  last: 1_763_300_030),
            .init(kind: "hub", stop: "server_unreached", cause: "none", count: 1, first: 1_763_300_020,
                  last: 1_763_300_020),
        ])
        let many = (0..<14).map { stop("mac", AppHealth.installStops[$0 + 1], "", Double($0)) }
        let newest = AppHealth.installs(many, since: Self.t0 - 1)
        #expect(newest.count == 10 && newest.first?.stop == AppHealth.installStops[14] && newest.last?.stop == AppHealth.installStops[5])
        #expect(AppHealth.installs([stop("join", "new_stop", "new_cause", 1)], since: Self.t0)
            == [.init(kind: "other", stop: "other", cause: "none", count: 1, first: 1_763_300_001, last: 1_763_300_001)])
    }
}

/// A site that never answers: the connection is lost, as on a Mac with no network.
final class NoAnswer: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

/// Our site as a stand-in: it keeps each request that it is asked, and answers with the status that the host's first
/// label names ("status-429.platform.founderizer.com" answers 429), else 200 `{"ok": true}`. Each test asks a host of its own,
/// so tests that run beside each other read only their own requests.
final class ErrorSite: URLProtocol, @unchecked Sendable {
    struct Asked: Sendable {
        let url: String
        let method: String?
        let headers: [String: String]
        let body: Data
    }
    nonisolated(unsafe) private static var all: [Asked] = []
    private static let lock = NSLock()

    static func asked(host: String) -> [Asked] { lock.withLock { all.filter { URL(string: $0.url)?.host == host } } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] { headers[name.lowercased()] = value }
        let asked = Asked(url: url.absoluteString, method: request.httpMethod, headers: headers, body: body)
        Self.lock.withLock { Self.all.append(asked) }
        let label = url.host?.split(separator: ".").first.map(String.init) ?? ""
        let status = label.hasPrefix("status-") ? Int(label.dropFirst(7)) ?? 200 : 200
        let answer = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                     headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: answer, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((status == 200 ? #"{"ok": true}"# : #"{"error": "refused", "says": "No."}"#).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
