import Testing
@testable import FleetCore

/// The text that the stop row's Report a problem puts into the report form's box (`InstallReport`).
@Suite struct InstallReportTests {
    /// What a join printed last when the server could not fetch the fleet's code from the hub's port 9418.
    private let joinLines = [
        "Founderizer: the Founderizer repository in /home/fleet/fleet-server",
        "fatal: unable to connect to 100.64.0.1:",
        "100.64.0.1[0: 100.64.0.1]: errno=Connection timed out",
        "",
        "Founderizer join stopped: Could not get the Founderizer repository from git://100.64.0.1/fleet-pilot.git. "
            + "Check the Tailscale access rules for the hub's port 9418.",
    ]
    private let stop = "Could not get the Founderizer repository from git://100.64.0.1/fleet-pilot.git. "
        + "Check the Tailscale access rules for the hub's port 9418."

    /// The step, the stop's line as the page says it, and the machine's own lines of that step, oldest first, with the
    /// empty ones left out: git's own words are what tell a dropped port from a stopped service.
    @Test func itHoldsTheStepTheStopAndTheMachinesLastLines() {
        let text = InstallReport.text(step: "Join the fleet", stop: stop, lines: joinLines)
        #expect(text == """
            The install stopped at “Join the fleet”.
            \(stop)

            The server's last lines:
            \(joinLines[0])
            \(joinLines[1])
            \(joinLines[2])
            \(joinLines[4])
            """)
        #expect(ProblemReport(text: text, email: "owner@example.com", facts: []).isReady)
    }

    /// The page's own line for a stop whose reason it cannot read names only the step, which the first line says.
    @Test func theStepIsSaidOnce() {
        let plain = InstallError.step("Check the server", "a line of no known shape").plain(host: "203.0.113.9", place: nil)
        #expect(plain == "It stopped at “Check the server”.")
        #expect(InstallReport.text(step: "Check the server", stop: plain, lines: []) == "The install stopped at “Check the server”.")
    }

    /// A stop before any step began, and a step that printed nothing: the stop's line alone, with no heading of lines.
    @Test func aStopWithNoStepOrNoLines() {
        #expect(InstallReport.text(step: nil, stop: "The hub gave no join line. Try again.", lines: [])
                == "The install stopped.\nThe hub gave no join line. Try again.")
        #expect(InstallReport.text(step: "", stop: "x", lines: ["", "  "]) == "The install stopped.\nx")
    }

    /// At most the last twelve lines, each cut to its length, and the newest ones that fit together, so that the box
    /// keeps room for the owner's own words under the website's limit.
    @Test func theLinesAreBounded() {
        let many = (1...30).map { "line \($0)" }
        let kept = InstallReport.kept(many)
        #expect(kept == (19...30).map { "line \($0)" })
        let long = String(repeating: "y", count: 1000)
        #expect(InstallReport.kept([long]) == [String(repeating: "y", count: InstallReport.maxLineLength)])
        let wide = (1...12).map { "\($0) " + String(repeating: "z", count: 400) }
        let fit = InstallReport.kept(wide)
        #expect(fit.last?.hasPrefix("12 ") == true)
        #expect(fit.reduce(0) { $0 + $1.count + 1 } <= InstallReport.maxLinesLength)
        #expect(fit.count == InstallReport.maxLinesLength / (InstallReport.maxLineLength + 1))
        let text = InstallReport.text(step: "Join the fleet", stop: stop, lines: wide)
        #expect(text.count + 1000 <= ProblemReport.maxText)
    }

    /// A line that holds something that looks like a key has it cut out, the stop's line too, so the app's own words
    /// never hold one and never keep Send waiting.
    @Test func whatLooksLikeAKeyIsCutOut() {
        let line = "export ANTHROPIC_API_KEY=sk-ant-api03-EXAMPLEEXAMPLEEXAMPLEEXAMPLE done"
        #expect(KeyInText.first(in: line) != nil)
        let kept = InstallReport.kept([line])
        #expect(kept == ["export ANTHROPIC_API_KEY=… done"])
        let text = InstallReport.text(step: "Join the fleet", stop: stop, lines: [line, line])
        #expect(!ProblemReport(text: text, email: "owner@example.com", facts: []).holdsKey)
        let keyed = InstallReport.text(step: "Join the fleet", stop: "It said: " + line, lines: [])
        #expect(keyed == "The install stopped at “Join the fleet”.\nIt said: export ANTHROPIC_API_KEY=… done")
        #expect(!ProblemReport(text: keyed, email: "owner@example.com", facts: []).holdsKey)
    }

    /// The one-time link code of a new hub never goes: its installer's line, which a step after the claim's wait can
    /// still hold (the plan's redactions do not know it), and a code in its three groups anywhere, the stop's line too.
    @Test func theLinkCodeNeverGoes() {
        let claim = "FLEET_CLAIM=ABCD-EFGH-JKLM sh -c \"$(curl -fsS http://100.64.0.1:8765/claim)\""
        #expect(ClaimCode.found(in: claim)?.code == "ABCDEFGHJKLM")
        #expect(InstallReport.kept([claim, "the code is ABCD-EFGH-JKLM.", "FLEET_CLAIM=x FLEET_CLAIM=y"]) == [
            "FLEET_CLAIM=… sh -c \"$(curl -fsS http://100.64.0.1:8765/claim)\"", "the code is ….",
            "FLEET_CLAIM=… FLEET_CLAIM=…"])
        let text = InstallReport.text(step: "Claim the hub", stop: "The hub refused ABCD-EFGH-JKLM.", lines: [claim])
        #expect(!text.contains("ABCD") && !text.contains("JKLM"))
        // Words of the same shape that are no code stay: a letter outside the code's alphabet, a longer run.
        #expect(InstallReport.kept(["ABCD-EFGH-IJKL", "ABCD-EFGH-JKLMN"]) == ["ABCD-EFGH-IJKL", "ABCD-EFGH-JKLMN"])
    }

    /// The stop's line is the page's, which can be a machine's whole line: it is cut to its own length, and with the
    /// longest step and lines the box keeps room for the owner's words under the website's limit.
    @Test func theStopLineIsBounded() {
        let long = String(repeating: "w", count: 5000)
        let text = InstallReport.text(step: long, stop: long, lines: (1...12).map { "\($0) " + long })
        #expect(text.contains(String(repeating: "w", count: InstallReport.maxStopLength)))
        #expect(!text.contains(String(repeating: "w", count: InstallReport.maxStopLength + 1)))
        #expect(text.count + 1000 <= ProblemReport.maxText)
    }

    /// In Spanish: the heading of the step and of the lines, and the page's own line for a step is still said once.
    @Test func inSpanish() throws {
        try SpanishTable.run {
            let text = InstallReport.text(step: "Unirse al equipo", stop: stop, lines: [joinLines[1]])
            #expect(text == "La instalación se detuvo en «Unirse al equipo».\n\(stop)\n\nÚltimas líneas del servidor:\n\(joinLines[1])")
            let plain = String(l10n: "It stopped at “\("Unirse al equipo")”.")
            #expect(plain == "Se detuvo en «Unirse al equipo».")
            #expect(InstallReport.text(step: "Unirse al equipo", stop: plain, lines: [])
                    == "La instalación se detuvo en «Unirse al equipo».")
        }
    }
}
