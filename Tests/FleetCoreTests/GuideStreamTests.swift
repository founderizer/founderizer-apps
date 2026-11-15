#if os(macOS)
import Foundation
import Testing
@testable import FleetCore

/// **The reader of the program's lines** (`GuideStream`) and the check at each turn (`GuideCheck`).
///
/// The fixture `guide-stream.jsonl` is made from the lines that Claude Code 2.1.312 printed in the probe of 14
/// November 2026, one of each kind, with each path, id, account number and time replaced by an example, and with the
/// probe's two tools renamed to the guide's. Its last line is the one that the live test of 15 November 2026 got for a
/// refused resume. The lines that neither reached (a limit, a missing sign-in) are made here from those lines, with the
/// words that the program's own file and the provider's pages give.
struct GuideStreamTests {
    /// The fixture's lines, in the order of `kinds`.
    private static let lines: [String] = {
        let url = Bundle.module.url(forResource: "guide-stream", withExtension: "jsonl", subdirectory: "Fixtures")!
        return try! String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }()

    private enum Kind: Int {
        case start, toolCall, toolResult, rateLimit, words, done, ownAnswer, ownDone, interruptTaken, ownerEcho
        case interrupted, toolProgress, refusedResume
    }

    private static func line(_ kind: Kind) -> String { lines[kind.rawValue] }

    /// A fixture's line with some fields changed.
    private static func line(_ kind: Kind, _ change: (inout [String: Any]) -> Void) -> String {
        var object = try! JSONSerialization.jsonObject(with: Data(line(kind).utf8)) as! [String: Any]
        change(&object)
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private static func events(_ line: String) -> [GuideEvent] {
        if case .events(let events) = GuideStream.read(line) { return events }
        Issue.record("the line is a start of a turn")
        return []
    }

    // MARK: each line gives the right event

    @Test func theFixtureHasOneLineOfEachKind() {
        #expect(Self.lines.count == 13)
    }

    @Test func theStartOfATurnGivesWhatTheModelHas() {
        guard case .start(let start) = GuideStream.read(Self.line(.start)) else {
            Issue.record("no start"); return
        }
        #expect(start.tools == GuideTool.list.map(GuideCheck.whole))
        #expect(start.servers == [GuideTurnStart.Server(name: "founderizer", status: "connected")])
        #expect(start.version == "2.1.312")
        // The probe ran with the program's own socket open: the line names it.
        #expect(start.hasMessagingSocket)
    }

    @Test func theGuidesWordsAndItsToolCalls() {
        #expect(Self.events(Self.line(.toolCall)) == [.toolCall(id: "toolu_example01", name: "mcp__founderizer__setup_state")])
        let words = Self.events(Self.line(.words))
        guard case .words(let text) = words.first, words.count == 1 else { Issue.record("no words"); return }
        #expect(text.hasPrefix("1. setup_state answer: example-word-1."))
    }

    @Test func aTurnsEnd() {
        #expect(Self.events(Self.line(.done)) == [.turnEnded(.done)])
        #expect(Self.events(Self.line(.interrupted)) == [.turnEnded(.interrupted)])
        #expect(Self.events(Self.line(.interruptTaken)) == [.interruptTaken])
    }

    @Test func theLineOfARefusedResumeIsAnErrorOfTheRun() {
        // 2.1.312 printed this one line for a resume of a session that it does not have, and ended with status 1 (the
        // live test of 15 November 2026). The runner reads it as a refused resume when it comes before a first turn.
        #expect(Self.events(Self.line(.refusedResume)) == [.stopped(.failed("error_during_execution"))])
    }

    @Test func theProgramsOwnAnswerIsNotTheGuidesWords() {
        // "/context" in the probe: the program answered by itself, with no call of the model.
        #expect(Self.events(Self.line(.ownAnswer)) == [.ownAnswer])
        #expect(Self.events(Self.line(.ownDone)) == [.turnEnded(.done)])
    }

    @Test func linesThatTheAppDoesNotDrawGiveNothing() {
        #expect(Self.events(Self.line(.toolResult)) == [])
        #expect(Self.events(Self.line(.ownerEcho)) == [])
        #expect(Self.events(Self.line(.toolProgress)) == [])
    }

    @Test func aLineOfAnUnknownTypeIsPassedOver() {
        #expect(Self.events(#"{"type":"a_later_versions_line","text":"anything"}"#) == [])
        #expect(Self.events(#"{"type":"system","subtype":"a_later_subtype"}"#) == [])
        #expect(Self.events("Not a JSON line at all") == [])
        #expect(Self.events("") == [])
        #expect(Self.events("[1, 2]") == [])
    }

    // MARK: a limit, and a sign-in that is gone

    @Test func anAllowedWindowIsNoLimit() {
        #expect(Self.events(Self.line(.rateLimit)) == [])
        let warned = Self.line(.rateLimit) { object in
            var info = object["rate_limit_info"] as! [String: Any]
            info["status"] = "allowed_warning"
            object["rate_limit_info"] = info
        }
        #expect(Self.events(warned) == [])
    }

    @Test func aStatusThatIsNotAllowedGivesALimitWithItsResetTime() {
        let rejected = Self.line(.rateLimit) { object in
            var info = object["rate_limit_info"] as! [String: Any]
            info["status"] = "rejected"
            info["rateLimitType"] = "five_hour"
            object["rate_limit_info"] = info
        }
        #expect(Self.events(rejected) == [.limit(resetsAt: Date(timeIntervalSince1970: 1_900_000_000))])
        let noTime = Self.line(.rateLimit) { object in
            object["rate_limit_info"] = ["status": "rejected"]
        }
        #expect(Self.events(noTime) == [.limit(resetsAt: nil)])
    }

    @Test func aResultWithARateLimitErrorGivesALimit() {
        let byWord = Self.line(.interrupted) { object in
            object["terminal_reason"] = nil
            object["error"] = "rate_limit"
        }
        #expect(Self.events(byWord) == [.limit(resetsAt: nil), .turnEnded(.failed)])
        let byStatus = Self.line(.interrupted) { object in
            object["terminal_reason"] = nil
            object["api_error_status"] = 429
        }
        #expect(Self.events(byStatus) == [.limit(resetsAt: nil), .turnEnded(.failed)])
    }

    @Test func aRetryBecauseOfTheLimitGivesALimit() {
        #expect(Self.events(#"{"type":"system","subtype":"api_retry","error":"rate_limit","attempt":1}"#) == [.limit(resetsAt: nil)])
        #expect(Self.events(#"{"type":"system","subtype":"api_retry","error":"server_error","attempt":1}"#) == [])
    }

    @Test func aMissingSignInIsSaidAndItsWordsAreNotTheGuides() {
        // With no sign-in the program prints its own words ("Not logged in") as an assistant line with this error.
        let said = Self.line(.words) { object in object["error"] = "authentication_failed" }
        #expect(Self.events(said) == [.notSignedIn])
        let ended = Self.line(.interrupted) { object in
            object["terminal_reason"] = nil
            object["error"] = "authentication_failed"
        }
        #expect(Self.events(ended) == [.notSignedIn, .turnEnded(.failed)])
    }

    @Test func eachOtherErrorStopsWithAFixedKindAndNoSentence() {
        let other = Self.line(.interrupted) { object in
            object["terminal_reason"] = nil
            object["subtype"] = "error_max_turns"
        }
        #expect(Self.events(other) == [.stopped(.failed("error_max_turns"))])
        #expect(GuideStream.kind("A whole sentence, with a path /Users/owner and more than forty characters of it") ==
                "awholesentencewithapathusersownerandmore")
        #expect(GuideStream.kind(nil) == "unknown")
    }

    // MARK: the check at each turn

    private static let check = GuideCheck(tools: GuideTool.list, version: "2.1.312")

    private static func start(tools: [String] = GuideTool.list.map(GuideCheck.whole),
                              servers: [GuideTurnStart.Server] = [.init(name: "founderizer", status: "connected")],
                              version: String = "2.1.312", socket: Bool = false) -> GuideTurnStart {
        GuideTurnStart(tools: tools, servers: servers, version: version, hasMessagingSocket: socket)
    }

    @Test func theGuidesListAndNoOtherNamePasses() {
        #expect(Self.check.stop(for: Self.start()) == nil)
        // The order of the names is the program's own.
        #expect(Self.check.stop(for: Self.start(tools: GuideTool.list.map(GuideCheck.whole).reversed())) == nil)
    }

    @Test func oneToolMoreOrLessStops() {
        let all = GuideTool.list.map(GuideCheck.whole)
        #expect(Self.check.stop(for: Self.start(tools: all + ["Bash"])) == .tools(unlisted: ["Bash"], missing: []))
        #expect(Self.check.stop(for: Self.start(tools: all + ["mcp__founderizer__grant_access"]))
                == .tools(unlisted: ["mcp__founderizer__grant_access"], missing: []))
        #expect(Self.check.stop(for: Self.start(tools: Array(all.dropLast())))
                == .tools(unlisted: [], missing: ["mcp__founderizer__finish"]))
    }

    @Test func anotherServerOrAHelperThatIsNotConnectedStops() {
        let helper = GuideTurnStart.Server(name: "founderizer", status: "connected")
        #expect(Self.check.stop(for: Self.start(servers: [helper, .init(name: "claude-in-chrome", status: "connected")])) == .servers)
        #expect(Self.check.stop(for: Self.start(servers: [.init(name: "founderizer", status: "failed")])) == .servers)
        #expect(Self.check.stop(for: Self.start(servers: [.init(name: "other", status: "connected")])) == .servers)
        #expect(Self.check.stop(for: Self.start(servers: [])) == .servers)
    }

    @Test func anotherVersionStops() {
        #expect(Self.check.stop(for: Self.start(version: "2.1.313")) == .version)
        #expect(Self.check.stop(for: Self.start(version: "")) == .version)
    }

    @Test func theProgramsOwnSocketForOtherSessionsStops() {
        #expect(Self.check.stop(for: Self.start(socket: true)) == .socket)
    }
}
#endif
