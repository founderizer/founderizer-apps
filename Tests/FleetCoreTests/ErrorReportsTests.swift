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
        for version in [nil, "", String(repeating: "1", count: 41), "0.1.285/286", "0.1.285\n(286)", "0.1.285\n", "0.1.285 «286»"] {
            #expect(ErrorReport(fleet: Self.fleet, version: version, system: nil, crashes: one) == nil)
        }
        #expect(ErrorReport(fleet: Self.fleet, version: String(repeating: "1", count: 40), system: nil, crashes: one) != nil)
        // An image's id ends where it ends: a final line break is no id (ICU's `$` would take one).
        #expect(ErrorReport.uuid("01234567-89AB-CDEF-0123-456789ABCDEF") == "01234567-89ab-cdef-0123-456789abcdef")
        #expect(ErrorReport.uuid("01234567-89ab-cdef-0123-456789abcdef\n") == nil)
        #expect(ErrorReport(fleet: Self.fleet, version: "0.1.285 (286)", system: nil, crashes: []) == nil)
        // The system is optional: one outside its pattern is left out, and the report still goes.
        for system in ["macOS/26", "macOS 26\n", String(repeating: "x", count: 41)] {
            #expect(ErrorReport(fleet: Self.fleet, version: "1", system: system, crashes: one)?.system == nil)
        }
        #expect(ErrorReport(fleet: Self.fleet, version: "1", system: nil, crashes: one)?.system == nil)
        #expect(ErrorReport(fleet: Self.fleet, version: "1", system: "Ubuntu 24.04", crashes: one)?.system == "Ubuntu 24.04")
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
        #expect(ErrorReport(fleet: Self.fleet, version: "1", system: nil, crashes: wrong) == nil)
        #expect(ErrorReport(fleet: Self.fleet, version: "1", system: nil, crashes: wrong + [crash()])?.crashes == [crash()])
    }

    @Test func atMostTwentyCrashesGoTheOnesSeenLast() throws {
        let many = (0..<25).map { crash(signal: $0, first: 1_763_300_000 + $0, last: 1_763_300_000 + $0) }
        let report = try #require(ErrorReport(fleet: Self.fleet, version: "1", system: nil, crashes: many))
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
        let report = try #require(ErrorReport(fleet: Self.fleet, version: String(repeating: "9", count: 40),
                                              system: String(repeating: "x", count: 40), crashes: crashes))
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
        #expect(try ErrorReportClient.endpoint(channel: nil).absoluteString == "https://founderizer.com/api/errors")
        #expect(try ErrorReportClient.endpoint(channel: " ").absoluteString == "https://founderizer.com/api/errors")
        #expect(try ErrorReportClient.endpoint(channel: "https://staging.founderizer.com").absoluteString
            == "https://staging.founderizer.com/api/errors")
        _ = try ErrorReportClient.endpoint(channel: "HTTPS://Staging.Founderizer.com")
        for bad in ["http://founderizer.com", "http://staging.founderizer.com", "https://example.com",
                    "https://founderizer.com.example.net", "https://xfounderizer.com", "ftp://founderizer.com", "https://",
                    "not a url", "https://user:pw@founderizer.com", "https://founderizer.com?x=1", "https://founderizer.com#x"] {
            #expect(throws: ErrorReportError.badChannel) { try ErrorReportClient.endpoint(channel: bad) }
        }
    }

    /// The rule is one function now, and Report a problem goes where it went: the same address for every channel that
    /// it took, and a refusal for every channel that it refused.
    @Test func reportAProblemGoesWhereItWent() throws {
        let taken = [nil, "", "  ", "https://founderizer.com", "https://staging.founderizer.com", "https://founderizer.com/"]
        let addresses = try taken.map { try ProblemReportClient.endpoint(channel: $0).absoluteString }
        #expect(addresses == ["https://founderizer.com/api/report", "https://founderizer.com/api/report",
                              "https://founderizer.com/api/report", "https://founderizer.com/api/report",
                              "https://staging.founderizer.com/api/report", "https://founderizer.com/api/report"])
        for channel in taken + ["HTTPS://Staging.Founderizer.com"] {
            #expect(try ErrorReportClient.endpoint(channel: channel).absoluteString
                == ProblemReportClient.endpoint(channel: channel).absoluteString.replacingOccurrences(of: "api/report", with: "api/errors"))
        }
        for bad in ["http://founderizer.com", "https://example.com", "https://founderizer.com.example.net",
                    "https://xfounderizer.com", "ftp://founderizer.com", "https://", "not a url",
                    "https://user:pw@founderizer.com", "https://founderizer.com?x=1"] {
            #expect(throws: ProblemReportError.self) { try ProblemReportClient.endpoint(channel: bad) }
        }
        #expect(OurSite.isOurs("founderizer.com") && OurSite.isOurs("A.Founderizer.COM"))
        #expect(!OurSite.isOurs("xfounderizer.com") && !OurSite.isOurs("founderizer.com.example.net"))
    }

    /// The one request to our site, as the site gets it: its address, POST, JSON, the report's own body, and no key,
    /// no cookie and no header of the fleet.
    @Test func theRequestCarriesTheReportAndNothingElse() async throws {
        let report = try #require(ErrorReport(fleet: Self.fleet, version: "0.1.285 (286)", system: "macOS 26.6.2",
                                              crashes: [crash(frames: [.init(image: Self.own, offset: 165304), .lib])]))
        try await ErrorReportClient(protocolClasses: [ErrorSite.self])
            .send(report, channel: "https://errors-ok.founderizer.com")
        let asked = try #require(ErrorSite.asked(host: "errors-ok.founderizer.com").first)
        #expect(asked.url == "https://errors-ok.founderizer.com/api/errors")
        #expect(asked.method == "POST")
        #expect(asked.headers["content-type"] == "application/json" && asked.headers["accept"] == "application/json")
        #expect(asked.headers["authorization"] == nil && asked.headers["cookie"] == nil)
        #expect(asked.headers[AppUpdate.fleetHeader.lowercased()] == nil)
        #expect(asked.body == (try report.body()))
    }

    @Test func everyAnswerButA200IsAFailedSend() async throws {
        let report = try #require(ErrorReport(fleet: Self.fleet, version: "1", system: nil, crashes: [crash()]))
        for status in [400, 429, 500] {
            await #expect(throws: ErrorReportError.refused(status)) {
                try await ErrorReportClient(protocolClasses: [ErrorSite.self])
                    .send(report, channel: "https://status-\(status).founderizer.com")
            }
        }
        // A redirect is an answer, never a second request: the other site sees nothing.
        await #expect(throws: ErrorReportError.refused(307)) {
            try await ErrorReportClient(protocolClasses: [RedirectingSite.self]).send(report, channel: nil)
        }
        let asked = RedirectingSite.asked()
        #expect(asked.contains("https://founderizer.com/api/errors"))
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
        let report = try #require(ErrorReport(fleet: Self.fleet, version: "1", system: nil, crashes: batch))
        func failure(_ channel: String, _ site: AnyClass = ErrorSite.self) async -> Error? {
            do { try await ErrorReportClient(protocolClasses: [site]).send(report, channel: channel); return nil } catch { return error }
        }
        for status in [400, 404, 413, 422] {
            try ErrorReport.keep([older], in: file)
            let error = try #require(await failure("https://status-\(status).founderizer.com"))
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
            let error = try #require(await failure("https://status-\(status).founderizer.com"))
            #expect(ErrorReportError.keeps(error))
            #expect(ErrorReport.settle(batch, carriedKept: true, after: error, in: file) == both)
            #expect(ErrorReport.kept(file) == both)
        }
        try ErrorReport.keep([older], in: file)
        let lost = try #require(await failure("https://errors-lost.founderizer.com", NoAnswer.self))
        #expect(lost is URLError && ErrorReportError.keeps(lost))
        #expect(ErrorReport.settle(batch, carriedKept: false, after: lost, in: file) == both)
        // A 200 that did not carry the file leaves it for the next start; one that carried it takes it away.
        #expect(await failure("https://errors-sent.founderizer.com") == nil)
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

/// A site that never answers: the connection is lost, as on a Mac with no network.
final class NoAnswer: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

/// Our site as a stand-in: it keeps each request that it is asked, and answers with the status that the host's first
/// label names ("status-429.founderizer.com" answers 429), else 200 `{"ok": true}`. Each test asks a host of its own,
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
