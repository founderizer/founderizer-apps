import FleetCore
import Foundation
import Testing
@testable import FleetOwnerAPI

/// `prepare_problem_report`: the owner's own agent writes a problem report into the app's own form, and the owner
/// sends it (`PrepareReport`).
final class OwnerProblemReportTests {
    let home = Fixture.home()
    deinit { try? FileManager.default.removeItem(at: home) }

    /// A stand-in for the app's part: what it was asked to show, and how its form takes it.
    final class Form: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        var outcome = PrepareReport.Outcome.shown
        var holdsKey: @Sendable (String) -> Bool = { KeyInText.contains($0) }

        var shown: [String] { lock.lock(); defer { lock.unlock() }; return list }

        /// Not in an async closure itself: a lock is no call for one.
        private func add(_ text: String) -> PrepareReport.Outcome {
            lock.lock(); defer { lock.unlock() }
            list.append(text)
            return outcome
        }

        var desk: PrepareReport.Desk {
            PrepareReport.Desk(holdsKey: { [self] in holdsKey($0) }, show: { [self] text in add(text) })
        }
    }

    private func context(_ link: ValueLink) -> OwnerContext {
        OwnerContext(hubSetting: { nil }, transport: Fixture.transport(), home: home, userAgent: "founderizer-cli/test",
                     ownBuild: nil, startedBuild: { nil }, clientLabel: { "founderizer-cli/1/test" },
                     appLink: link.appLink(), standardInput: .none)
    }

    private func program() throws -> URL {
        let folder = home.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = Bundle.module.url(forResource: "owner-tools", withExtension: "json", subdirectory: "Fixtures")!
        try? FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("owner-tools.json"))
        return folder.appendingPathComponent("founderizer-cli")
    }

    private func run(_ arguments: [String], _ link: ValueLink) throws -> (Int32, [String], [String]) {
        let out = Lines()
        var errors: [String] = []
        let status = OwnerCLI.run(arguments: arguments, executable: try program(), context: context(link),
                                  version: "0.1.0", input: { nil }, output: { out.add($0) },
                                  errors: { errors.append($0) })
        return (status, out.all, errors)
    }

    private static let shownAnswer = ChannelClient.Reach.answer(.result(.object(["shown": .bool(true)])))

    // ------------------------------------------------------------ the field

    /// The one field is `text`: a string of 1 to 4000 characters after the white space at its ends is gone.
    @Test func theTextHasOneForm() {
        #expect(PrepareReport.read(["text": .string("  The install stopped at the network step.\n")])
                == .success("The install stopped at the network step."))
        #expect(PrepareReport.read(["text": .string(String(repeating: "a", count: 4000))])
                == .success(String(repeating: "a", count: 4000)))
        for bad: [String: JSONValue] in [[:], ["text": .string("")], ["text": .string(" \n\t ")], ["text": .int(7)],
                                         ["text": .bool(true)], ["text": .array([.string("a")])], ["text": .null],
                                         ["text": .string(String(repeating: "a", count: 4001))]] {
            #expect(PrepareReport.read(bad) == .failure(.init(PrepareReport.textWord)), "\(bad)")
        }
        // A report of a few letters says nothing: 20 characters at least.
        #expect(PrepareReport.read(["text": .string(String(repeating: "a", count: 19))]) == .failure(.init(PrepareReport.textWord)))
        #expect(PrepareReport.read(["text": .string(String(repeating: "a", count: 20))]) == .success(String(repeating: "a", count: 20)))
        // Each other field is refused, with a text that is right too: a reply address is the owner's to give.
        for other in ["email", "facts", "send", "path", "value"] {
            #expect(PrepareReport.read(["text": .string("The install stopped at step nine."), other: .string("x")])
                    == .failure(.init(PrepareReport.only)), "\(other)")
        }
        // The bound is the form's own, and this tool counts it as the website does, in UTF-16 units: a text that
        // the tool takes is never one that the website refuses for its length.
        #expect(PrepareReport.maxText == ProblemReport.maxText)
        let pair = "\u{1F600}"                                  // one character, two UTF-16 units
        #expect(PrepareReport.read(["text": .string(String(repeating: pair, count: 2000))])
                == .success(String(repeating: pair, count: 2000)))
        #expect(PrepareReport.read(["text": .string(String(repeating: pair, count: 2001))])
                == .failure(.init(PrepareReport.textWord)))
    }

    // ------------------------------------------------------------ the app's answer

    @Test func aTextThatTheFormTakesIsShownOnce() async {
        let form = Form()
        let answer = await PrepareReport.answer(fields: ["text": .string(" The hub did not answer after the update. ")],
                                                value: nil, desk: form.desk)
        #expect(answer == .result(.object(["shown": .bool(true)])))
        #expect(form.shown == ["The hub did not answer after the update."])
    }

    /// The form's own word decides: text that the owner wrote stays, a window that cannot open is said, and an ask
    /// that another one replaced is said.
    @Test func theFormsOutcomeIsTheAnswer() async {
        for (outcome, words) in [(PrepareReport.Outcome.ownText, PrepareReport.ownText),
                                 (.noWindow, PrepareReport.noWindow), (.ended, PrepareReport.ended)] {
            let form = Form()
            form.outcome = outcome
            #expect(await PrepareReport.answer(fields: ["text": .string("The install stopped at step nine.")], value: nil, desk: form.desk)
                    == .refused(words))
        }
    }

    /// **Nothing shows before the checks passed**: a wrong field, a part after the request line and a text that holds
    /// something like a key are refused with the form not asked.
    @Test func aRefusalShowsNothing() async {
        let form = Form()
        #expect(await PrepareReport.answer(fields: [:], value: nil, desk: form.desk) == .refused(PrepareReport.textWord))
        #expect(await PrepareReport.answer(fields: ["text": .string("x"), "email": .string("a@example.com")],
                                           value: nil, desk: form.desk) == .refused(PrepareReport.only))
        let part = OwnerChannel.Value(copying: Data("more".utf8))
        #expect(await PrepareReport.answer(fields: ["text": .string("The install stopped at step nine.")], value: part, desk: form.desk)
                == .refused(PrepareReport.noPart))
        // The form's own check of a key in text (`KeyInText`), on an example key that is no real one.
        let key = "sk-ant-api03-" + String(repeating: "A1b2C3d4", count: 12)
        #expect(KeyInText.contains("The provider said no. My key is \(key)"))
        #expect(await PrepareReport.answer(fields: ["text": .string("The provider said no. My key is \(key)")],
                                           value: nil, desk: form.desk) == .refused(PrepareReport.holdsKey))
        #expect(form.shown.isEmpty)
    }

    /// A call that ended before the form was asked shows nothing.
    @Test func aCallThatEndedShowsNothing() async {
        let form = Form()
        let task = Task { () -> OwnerChannel.Answer in
            withUnsafeCurrentTask { $0?.cancel() }
            return await PrepareReport.answer(fields: ["text": .string("The install stopped at step nine.")], value: nil, desk: form.desk)
        }
        #expect(await task.value == .refused(PrepareReport.ended))
        #expect(form.shown.isEmpty)
    }

    /// **A refusal quotes nothing that the caller sent**: a marker in the text, in a field's name and in a field's
    /// value is in no answer.
    @Test func theRefusalsQuoteNothing() async {
        let marker = "ZQX-MARKER-91"
        let form = Form()
        form.holdsKey = { _ in true }
        var said: [String] = []
        for fields: [String: JSONValue] in [["text": .string("\(marker) is in this text of the agent.")], [marker: .string("x")],
                                            ["text": .string("x"), "other": .string(marker)], ["text": .array([.string(marker)])]] {
            if case .refused(let words) = await PrepareReport.answer(fields: fields, value: nil, desk: form.desk) {
                said.append(words)
            }
            if case .failure(let refusal) = PrepareReport.read(fields) { said.append(refusal.text) }
        }
        form.holdsKey = { _ in false }
        for outcome in [PrepareReport.Outcome.ownText, .noWindow, .ended] {
            form.outcome = outcome
            if case .refused(let words) = await PrepareReport.answer(fields: ["text": .string("\(marker) is in this text of the agent.")], value: nil,
                                                                     desk: form.desk) { said.append(words) }
        }
        #expect(said.count >= 7)
        #expect(said.allSatisfy { !$0.contains(marker) })
        #expect(!PrepareReport.notKnownHere.contains(marker))
    }

    // ------------------------------------------------------------ the program

    @Test func theToolIsAWriteOfTheProgramAlone() throws {
        let tools = OwnerTools(table: Fixture.table, context: context(ValueLink()))
        let tool = try #require(tools.listed.first { $0.name == PrepareReport.name })
        #expect(tool.annotations == .object(["readOnlyHint": .bool(false)]))
        #expect(tool.inputSchema["additionalProperties"] == .bool(false))
        #expect(tool.inputSchema["required"] == .array([.string("text")]))
        #expect(OwnerTools.verb(of: tool) == .write)
        #expect(Fixture.table.tool(PrepareReport.name) == nil)
        #expect(tool.description.contains("sends nothing") && tool.description.contains("Only the owner sends it"))
        let (status, out, _) = try run(["tools"], ValueLink())
        #expect(status == 0 && out.contains { $0.hasPrefix("write prepare_problem_report: Setup: Prepares a problem report") })
    }

    /// `write` sends the one field, with no white space at its ends and with no part after the line; `call` refuses
    /// the tool, because it is a write.
    @Test func writeSendsTheTextAndCallRefusesIt() throws {
        let link = ValueLink(Self.shownAnswer)
        let (status, out, errors) = try run(["write", "prepare_problem_report", #"{"text": "  The build stopped at step nine.  "}"#], link)
        #expect(status == 0 && errors.isEmpty)
        #expect(out.joined().contains("\"shown\""))
        #expect(link.all.count == 1)
        #expect(link.all.first?.0.tool == PrepareReport.name)
        #expect(link.all.first?.0.fields == ["text": .string("The build stopped at step nine.")])
        #expect(link.all.first?.1 == nil)
        let reads = ValueLink(Self.shownAnswer)
        let (refused, _, said) = try run(["call", "prepare_problem_report", #"{"text": "The build stopped at step nine."}"#], reads)
        #expect(refused == 1 && reads.all.isEmpty)
        #expect(said.joined().contains("write"))
    }

    /// A field that is wrong never reaches the app.
    @Test func aWrongFieldIsRefusedInTheProgram() throws {
        for (arguments, words) in [(#"{}"#, PrepareReport.textWord), (#"{"text": 7}"#, PrepareReport.textWord),
                                   (#"{"text": "x", "send": true}"#, PrepareReport.only)] {
            let link = ValueLink(Self.shownAnswer)
            let (status, _, said) = try run(["write", "prepare_problem_report", arguments], link)
            #expect(status == 1 && link.all.isEmpty, "\(arguments)")
            #expect(said == [words], "\(arguments)")
        }
    }

    /// After its request went out, a lost answer says what is not known in this tool's own words, and that nothing is
    /// sent by it; the bot token's tool keeps its own.
    @Test func aLostAnswerHasThisToolsOwnWords() {
        for words in [ChannelClient.noAnswer, ChannelClient.closedNoAnswer, ChannelClient.unreadable] {
            let link = AppLink(exchange: { _, _ in .failed(words) }, start: { false }, pause: {}, tries: 0)
            #expect(link.call(tool: PrepareReport.name, fields: ["text": .string("x")]) == (PrepareReport.notKnownHere, true))
            #expect(link.call(tool: SaveBotToken.name, fields: [:]) == (SaveBotToken.notKnownHere, true))
        }
        #expect(PrepareReport.notKnownHere.contains("not known") && PrepareReport.notKnownHere.contains("Nothing is sent"))
    }

    /// The fact that the report carries for an agent's text is short enough for the form's row and for the website.
    @Test func theFactOfAnAgentsTextIsOneShortRow() {
        #expect(ProblemReport.writtenByAgent.name == "Written by")
        #expect(ProblemReport.writtenByAgent.value == "Your AI agent")
        #expect(ProblemReport.writtenByAgent.name.count <= 40 && ProblemReport.writtenByAgent.value.count <= 48)
    }
}
