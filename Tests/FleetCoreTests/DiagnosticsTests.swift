import Foundation
import Testing
@testable import FleetCore

/// The hub's own faults and refused calls in Report a problem and System status (owner feature `diagnostics`; the
/// owner's yes of 14 November 2026 to the pictures C0, E1, E2 and E3, "make sure we include all relevant inforamtion
/// that is SAFE to send"). Most of these are about what must NOT reach a report: words, a path, a key, a name of the
/// fleet's work, also from a hub that is wrong or is not ours.
struct DiagnosticsTests {
    private func fault(_ kind: String = "KeyError", frames: [(String, Int)] = [("hub.py", 32044), ("hub.py", 31761)],
                       count: Int = 3, errno: Int? = nil, http: Int? = nil) -> HubDiagnostics.Fault {
        .init(kind: kind, frames: frames.map { .init(file: $0.0, line: $0.1) }, errno: errno, http: http, count: count,
              first: 1_731_590_000, last: 1_731_593_000)
    }

    private func refusal(_ tool: String = "send_message", count: Int = 2) -> HubDiagnostics.Refusal {
        .init(tool: tool, file: "hub.py", line: 28470, count: count, first: 1_731_590_000, last: 1_731_593_000)
    }

    // ------------------------------------------------------------ what the hub answers

    @Test func theHubsAnswerDecodesWithItsClassKey() throws {
        let json = #"""
        {"faults": [{"program": "hub", "class": "KeyError", "frames": [{"file": "hub.py", "line": 32044},
          {"file": "lib", "line": 0}, {"file": "hub.py", "line": 31761}], "errno": null, "http": null, "count": 3,
          "first": 1731590000.5, "last": 1731593000.25}],
         "refusals": [{"tool": "send_message", "file": "hub.py", "line": 28470, "count": 2, "first": 1.0, "last": 2.0}],
         "db": "abc"}
        """#
        let answer = try JSONDecoder().decode(HubDiagnostics.self, from: Data(json.utf8)).checked()
        #expect(answer.faults.count == 1 && answer.refusals.count == 1 && answer.db == "abc")
        #expect(HubDiagnostics.lastError(answer.faults[0]) == "KeyError at hub.py 31761, from hub.py 32044. 3 times.")
    }

    @Test func aValueOutOfItsShapeDropsItsEntry() {
        let words = "sk-ant-api03-CANARYCANARYCANARYCANARY for Ana's task"
        let answer = HubDiagnostics(faults: [
            fault(),
            fault(frames: [(["", "Users", "ana", "secret.py"].joined(separator: "/"), 3)]),     // a path of a machine
            fault(frames: [("../hub.py", 3)]),
            fault(frames: [(words, 3)]),
            fault(frames: [("lib", 7)]),                              // a library frame has no line
            fault(frames: []),
            fault(frames: Array(repeating: ("hub.py", 1), count: 13)),
            fault(count: 0),
            fault(http: 999),
        ], refusals: [refusal(), refusal(words), refusal("Send Message"), refusal(count: -1)]).checked()
        #expect(answer.faults.count == 1)
        #expect(answer.refusals.count == 1)
        #expect(!"\(answer)".contains("CANARY") && !"\(answer)".contains("Ana"))
    }

    @Test func aClassThatIsNotOnTheHubsListIsOther() {
        // A class name with the shape of a cloud key, made here so that no file of the public copy holds one.
        let keyShaped = "AKIA" + String(repeating: "B", count: 16)
        let answer = HubDiagnostics(faults: [fault(keyShaped), fault("CanaryLeak")], refusals: []).checked()
        #expect(answer.faults.map(\.kind) == ["other", "other"])
    }

    // ------------------------------------------------------------ the lines that the app writes

    @Test func lastErrorSaysWhereItWasRaisedWhoCalledItAndHowManyTimes() {
        #expect(HubDiagnostics.lastError(fault()) == "KeyError at hub.py 31761, from hub.py 32044. 3 times.")
        #expect(HubDiagnostics.lastError(fault(frames: [("hub.py", 10)], count: 1)) == "KeyError at hub.py 10. Once.")
        #expect(HubDiagnostics.lastError(fault("HTTPError", frames: [("lib", 0), ("hub.py", 41190), ("lib", 0)], http: 503))
            == "HTTPError 503 at hub.py 41190. 3 times.")
        #expect(HubDiagnostics.lastError(fault("PermissionError", frames: [("lib", 0)], count: 1, errno: 13))
            == "PermissionError errno 13. Once.")
    }

    @Test func hubErrorsListsEachFaultAndThenTheRefusedCalls() {
        let answer = HubDiagnostics(faults: [fault(), fault("TimeoutError", frames: [("hub.py", 41190)], count: 1)],
                                    refusals: [refusal()])
        #expect(answer.errorsLine == "KeyError at hub.py 31761, 3 times. TimeoutError at hub.py 41190, once. "
            + "Refused: send_message at hub.py 28470, 2 times.")
        #expect(HubDiagnostics(faults: [], refusals: [refusal(), refusal("read_knowledge", count: 1)]).errorsLine
            == "Refused: send_message at hub.py 28470, 2 times; read_knowledge at hub.py 28470, once.")
        #expect(HubDiagnostics(faults: [], refusals: []).errorsLine == nil)
    }

    @Test func hubErrorsStaysUnder420CharactersAndCountsWhatDidNotFit() throws {
        let many = (1...40).map { fault(frames: [("hub.py", 10_000 + $0)], count: $0) }
        let line = try #require(HubDiagnostics(faults: many, refusals: [refusal()]).errorsLine)
        #expect(line.count <= HubDiagnostics.mostWords)
        #expect(line.range(of: #"; \+\d+ more\.$"#, options: .regularExpression) != nil)
    }

    @Test func theClientGivesBackOnlyWhatChecked() async throws {
        let site = try OneAnswer(status: "200 OK") { _ in
            #"{"faults": [{"program": "hub", "class": "CanaryLeak", "frames": [{"file": "Acme.py", "line": 3},"#
                + #"{"file": "hub.py", "line": 10}], "errno": null, "http": null, "count": 1, "first": 1, "last": 2},"#
                + #"{"program": "helper", "class": "KeyError", "frames": [{"file": "hub.py", "line": 1}], "errno": null,"#
                + #""http": null, "count": 1, "first": 1, "last": 2}], "refusals": [], "db": "abc"}"#
        }
        let answer = try await HubClient().diagnostics(hub: URL(string: "http://127.0.0.1:\(site.port)")!, database: "abc")
        #expect(answer.faults.count == 1)
        #expect(answer.faults[0].kind == "other")
        #expect(answer.faults[0].frames == [.init(file: "lib", line: 0), .init(file: "hub.py", line: 10)])
        #expect(site.received.starts(with: Data("GET /ui/diagnostics?db=abc HTTP/1.1\r\n".utf8)))
    }

    @Test func aNumberOutOfRangeOrAPlaceOffTheListIsCheckedToo() {
        let answer = HubDiagnostics(faults: [fault(errno: 200_000), fault(http: 99), fault()],
                                    refusals: [.init(tool: "send_message", file: "lib", line: 3, count: 1, first: 1, last: 2)])
            .checked()
        #expect(answer.faults.count == 1)
        #expect(answer.refusals.map(\.file) == ["lib"] && answer.refusals.map(\.line) == [0])
    }

    // ------------------------------------------------------------ a stall (UI-API.md 1.284)

    /// The owner's "Yes, reports only" of 21 November 2026, to the picture of the "Last error" row: a stall is said as
    /// "Stall" in the rows of a fault; a kind that is not one of the hub's drops it; a hub before 1.284 sends none.
    @Test func aStallIsSaidAsStallInTheRowsOfAFault() throws {
        let json = #"""
        {"faults": [], "refusals": [], "db": "abc",
         "stalls": [{"kind": "busy", "frames": [{"file": "lib", "line": 0}, {"file": "hub.py", "line": 74318},
           {"file": "hub.py", "line": 5574}], "count": 1, "first": 1731590000.5, "last": 1731590240.5},
          {"kind": "Read the vault", "frames": [{"file": "hub.py", "line": 1}], "count": 1, "first": 1.0, "last": 2.0}]}
        """#
        let answer = try JSONDecoder().decode(HubDiagnostics.self, from: Data(json.utf8)).checked()
        #expect(answer.stalls.map(\.kind) == ["busy"])
        #expect(answer.rows(macHasItsOwnError: false).lastError == "Stall at hub.py 5574, from hub.py 74318. Once.")
        let more = HubDiagnostics(faults: [fault()], refusals: [], stalls: answer.stalls)
        #expect(more.rows(macHasItsOwnError: false).hubErrors
                == "KeyError at hub.py 31761, 3 times. Stall at hub.py 5574, once.")
        // Beside the Mac's own error it goes to "Hub errors"; one with no place in the code says no place.
        #expect(answer.rows(macHasItsOwnError: true).hubErrors == "Stall at hub.py 5574, once.")
        let nowhere = HubDiagnostics(faults: [], refusals: [], stalls: [.init(kind: "paused", frames: [.init(file: "lib",
                                     line: 0)], count: 2, first: 1_731_590_000, last: 1_731_590_009)]).checked()
        #expect(nowhere.rows(macHasItsOwnError: false).lastError == "Stall. 2 times.")
        let older = try JSONDecoder().decode(HubDiagnostics.self, from: Data(#"{"faults": [], "refusals": []}"#.utf8))
        #expect(older.stalls.isEmpty)
    }

    // ------------------------------------------------------------ which row says it

    @Test func oneErrorShowsOnceNeverInTwoRows() {
        let one = HubDiagnostics(faults: [fault()], refusals: [])
        #expect(one.rows(macHasItsOwnError: false).lastError == "KeyError at hub.py 31761, from hub.py 32044. 3 times.")
        #expect(one.rows(macHasItsOwnError: false).hubErrors == nil)
        // The Mac's own error keeps "Last error", so the hub's goes to its own row.
        #expect(one.rows(macHasItsOwnError: true).lastError == nil)
        #expect(one.rows(macHasItsOwnError: true).hubErrors == "KeyError at hub.py 31761, 3 times.")
        let more = HubDiagnostics(faults: [fault()], refusals: [refusal()])
        #expect(more.rows(macHasItsOwnError: false).lastError == nil)
        #expect(more.rows(macHasItsOwnError: false).hubErrors != nil)
        let two = HubDiagnostics(faults: [fault(), fault("TimeoutError", frames: [("hub.py", 41190)], count: 1)],
                                 refusals: [])
        #expect(two.rows(macHasItsOwnError: false).lastError == nil)
        #expect(two.rows(macHasItsOwnError: false).hubErrors == "KeyError at hub.py 31761, 3 times. TimeoutError at hub.py 41190, once.")
        let none = HubDiagnostics(faults: [], refusals: []).rows(macHasItsOwnError: false)
        #expect(none.lastError == nil && none.hubErrors == nil)
    }

    @Test func theHubsWarningIsLeftOutOnlyWhereARowSaysTheFaults() {
        let faults = HubDiagnostics(faults: [fault()], refusals: [])
        #expect(faults.said((lastError: nil, hubErrors: nil)).isEmpty)
        #expect(faults.said((lastError: "KeyError at hub.py 1. Once.", hubErrors: nil)) == ["hub_fault"])
        #expect(faults.said((lastError: nil, hubErrors: "KeyError at hub.py 1, once.")) == ["hub_fault"])
        // Rows that say only a stall say no fault: the hub's warning, which counts no stall, stays in the findings.
        let stall = HubDiagnostics(faults: [], refusals: [], stalls: [.init(kind: "hold", frames: [.init(file: "hub.py",
                                   line: 5574)], count: 1, first: 1_731_590_000, last: 1_731_590_004)])
        #expect(stall.said((lastError: "Stall at hub.py 5574. Once.", hubErrors: nil)).isEmpty)
    }

    @Test func aLineThatLooksLikeAKeyIsNeitherShownNorSent() {
        // A file name of the right shape can still hold the shape of a key: the last check drops its line.
        let file = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345.py"
        let rows = HubDiagnostics(faults: [fault(frames: [(file, 1)])], refusals: []).rows(macHasItsOwnError: false)
        #expect(rows.lastError == nil && rows.hubErrors == nil)
    }

    @Test func aFileOrAToolPlaceThatIsNotOnTheAppsListIsLib() {
        let answer = HubDiagnostics(faults: [fault(frames: [("Acme_layoffs_list.py", 3), ("hub.py", 10)])],
                                    refusals: [.init(tool: "send_message", file: "Acme_merger.py", line: 4, count: 1,
                                                     first: 1, last: 2)]).checked()
        #expect(answer.faults[0].frames == [.init(file: "lib", line: 0), .init(file: "hub.py", line: 10)])
        #expect(answer.errorsLine == "KeyError at hub.py 10, 3 times. Refused: send_message, once.")
        #expect(!(answer.errorsLine ?? "").contains("Acme"))
    }

    @Test func aLineBreakInAValueDropsItsEntry() {
        let answer = HubDiagnostics(faults: [fault(frames: [("hub.py\n", 3)])],
                                    refusals: [refusal("send_message\n"), refusal("send_message\r\n"),
                                               refusal("send_message\u{2028}")]).checked()
        #expect(answer.faults.isEmpty && answer.refusals.isEmpty)
    }

    @Test func lastErrorStaysWithinTheSitesLimit() {
        let long = fault(frames: [(String(repeating: "a", count: 296) + ".py", 1), (String(repeating: "b", count: 296) + ".py", 2)])
        #expect(HubDiagnostics.lastError(long).hasSuffix("…"))
        #expect(HubDiagnostics.lastError(long).count <= HubDiagnostics.mostWords)
    }

    // ------------------------------------------------------------ System status (E1)

    /// **While the switch Help improve Founderizer is off, the block of the hub's own faults has the button to that
    /// switch beside Report a problem, and only then** (the owner, 25 November 2026: "show a button there to be able
    /// to go to the telemetry setting t send it automatically"). The bugs that it catches: the button while the switch is
    /// on, the button gone while it is off, and the button on a block of another warning.
    @Test func theHubsFaultWarningHasItsTitleAndOpensReportAProblem() {
        let warning = FleetHealth.Warning(kind: "hub_fault", detail: "3 times since 14:53.")
        #expect(warning.title == "The hub hit an error")
        #expect(warning.act == .tellUs)
        let other = FleetHealth.Warning(kind: "integrity", detail: "The check failed.")
        #expect(FleetHealth.blocks([warning, other], reportsOff: true).map(\.acts) == [[.tellUs, .openReports], [.tellUs]])
        #expect(FleetHealth.blocks([warning, other], reportsOff: false).map(\.acts) == [[.tellUs], [.tellUs]])
        #expect(FleetHealth.blocks([warning]).first?.acts == [.tellUs])
        #expect(FleetHealth.Warning.Act.openReports.label == "Help improve Founderizer")
    }
}
