import Darwin
import Foundation
import Testing
@testable import FleetCore
@testable import FleetOwnerAPI

// **`save_secret`, wired** (the secrets plan, step E4): the tool in the program's list, the program's side of one
// call (`OwnerTools.linkWrite`), the words for a lost answer, and the whole way on a socket of the test's own, to the
// tool's logic with a stand-in desk. The app's own desk (`LinkTools.secretDesk`) is in the app target, which has no
// tests: its pure rules are in FleetCore (`SecretOfFields`, `ShownFeatures`, `VaultSealKey`, `SecretRoom`), and the
// stand-in desk here asks the same ones. No test sends anything to a hub, reads the real clipboard or the real
// standard input, or holds a value with the form of a real service's key.

/// A standard input that counts each look at it: a test that must read none holds the count at 0.
final class LookedInput: @unchecked Sendable {
    private let lock = NSLock()
    private var looks = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return looks }
    private func add() { lock.lock(); looks += 1; lock.unlock() }

    var input: StandardInput {
        StandardInput(isTerminal: { [self] in add(); return false }, read: { [self] _ in add(); return 0 })
    }
}

/// **The program's side of `save_secret`**, with a stand-in link: what one call reads on this Mac, what it sends, and
/// what it says when its answer is lost.
final class OwnerSaveSecretProgramTests {
    let home = Fixture.home()
    deinit { try? FileManager.default.removeItem(at: home) }

    static let key: [String: JSONValue] = ["kind": .string("api_key"), "env": .string("EXAMPLE_API_KEY")]
    static let doneAnswer = JSONValue.object(["request_id": .string(SaveSecretSample.id), "state": .string("done"),
                                              "reference": .string(SaveSecretSample.reference),
                                              "title": .string("EXAMPLE_API_KEY"), "kind": .string("api_key")])

    private func context(_ link: ValueLink, input: StandardInput = .none) -> OwnerContext {
        OwnerContext(hubSetting: { nil }, transport: Fixture.transport(), home: home, userAgent: "founderizer-cli/test",
                     ownBuild: nil, startedBuild: { nil }, clientLabel: { "founderizer-cli/1/test" },
                     appLink: link.appLink(), standardInput: input)
    }

    private func program() throws -> URL {
        let folder = home.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = Bundle.module.url(forResource: "owner-tools", withExtension: "json", subdirectory: "Fixtures")!
        try? FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("owner-tools.json"))
        return folder.appendingPathComponent("founderizer-cli")
    }

    private func run(_ arguments: [String], _ link: ValueLink,
                     input: StandardInput = .none) throws -> (Int32, [String], [String]) {
        let out = Lines()
        var errors: [String] = []
        let status = OwnerCLI.run(arguments: arguments, executable: try program(), context: context(link, input: input),
                                  version: "0.1.0", input: { nil }, output: { out.add($0) },
                                  errors: { errors.append($0) })
        return (status, out.all, errors)
    }

    /// A file as a real one is: the value and one line end.
    private func valueFile(_ name: String = "example-key.txt") -> String {
        let place = home.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: place, contents: Data((exampleSecretValue + "\n").utf8))
        return place
    }

    private func with(_ more: [String: JSONValue]) -> [String: JSONValue] { Self.key.merging(more) { $1 } }

    /// **The tool is a write of the program alone**: listed with the others, taken by `write` and by the MCP form,
    /// refused by `call`, and no tool of `owner_mcp.py`'s table.
    @Test func theToolIsAWriteOfTheProgramAlone() throws {
        let tools = OwnerTools(table: Fixture.table, context: context(ValueLink()))
        let tool = try #require(tools.listed.first { $0.name == SaveSecret.name })
        #expect(tool.annotations == .object(["readOnlyHint": .bool(false)]))
        #expect(tool.inputSchema["required"] == nil && tool.inputSchema["additionalProperties"] == .bool(false))
        #expect(OwnerTools.verb(of: tool) == .write)
        #expect(tools.listed.last?.name == SaveSecret.name)
        #expect(Fixture.table.tool(SaveSecret.name) == nil)
        let (status, out, _) = try run(["tools"], ValueLink())
        #expect(status == 0)
        #expect(out.contains { $0.hasPrefix("write save_secret: Saves a new login or a new API key of the fleet into "
                                            + "the fleet's central vault.") })
        #expect(out.filter { $0.hasPrefix("write save_secret") }.count == 1)
    }

    /// **`write` takes it, makes the id, sends no path, and sends the file's bytes as they are.** The line end of
    /// the file goes to the app with the value: the app takes it off, and the program changes nothing.
    @Test func writeTakesItMakesTheIdAndSendsNoPath() throws {
        let link = ValueLink(.answer(.result(Self.doneAnswer)))
        let place = valueFile()
        let (status, out, said) = try run(["write", "save_secret",
                                           JSONValue.object(with(["from": .string("file"), "path": .string(place),
                                                                  "url": .string("https://api.example.com/v1")]))
                                               .dumps()], link)
        #expect(status == 0 && said.isEmpty)
        #expect(JSONValue.parse(out.joined()) == Self.doneAnswer)
        let sent = try #require(link.all.first)
        let made = try #require(sent.0.fields["request_id"]?.string)
        #expect(LinkWork.isID(made))
        #expect(sent.0 == OwnerChannel.Request(set: "owner", tool: "save_secret",
                                               fields: ["request_id": .string(made), "kind": .string("api_key"),
                                                        "env": .string("EXAMPLE_API_KEY"),
                                                        "url": .string("https://api.example.com/v1"),
                                                        "from": .string("file")]))
        #expect(sent.1 == Data((exampleSecretValue + "\n").utf8))
        #expect(!String(decoding: sent.0.line, as: UTF8.self).contains(place))
        #expect(!String(decoding: sent.0.line, as: UTF8.self).contains(exampleSecretValue))
        // Each call with no id gets an id of its own; a given id is sent as it is, and none is made.
        _ = try run(["write", "save_secret",
                     JSONValue.object(with(["from": .string("file"), "path": .string(place)])).dumps()], link)
        let second = try #require(link.all.last?.0.fields["request_id"]?.string)
        #expect(LinkWork.isID(second) && second != made)
        _ = try run(["write", "save_secret",
                     JSONValue.object(with(["from": .string("file"), "path": .string("~/example-key.txt"),
                                            "request_id": .string(SaveSecretSample.id)])).dumps()], link)
        #expect(link.all.count == 3 && link.all.last?.0.fields["request_id"] == .string(SaveSecretSample.id))
        // "~" is this program's home, as the file tools take it.
        #expect(link.all.last?.1 == Data((exampleSecretValue + "\n").utf8))
    }

    /// `write` reads a pipe to its end and never a terminal; `call` refuses the tool, because it is a write.
    @Test func writeReadsAPipeAndCallRefusesIt() throws {
        let link = ValueLink(.answer(.result(Self.doneAnswer)))
        let piped = JSONValue.object(with(["from": .string("stdin")])).dumps()
        let (status, _, _) = try run(["write", "save_secret", piped], link,
                                     input: FakeInput(Array(exampleSecretValue.utf8)).input())
        #expect(status == 0 && link.all.count == 1)
        #expect(link.all.first?.1 == Data(exampleSecretValue.utf8))
        #expect(link.all.first?.0.fields["from"] == .string("stdin") && link.all.first?.0.fields["path"] == nil)
        let (terminal, _, said) = try run(["write", "save_secret", piped], link,
                                          input: FakeInput(Array(exampleSecretValue.utf8)).input(terminal: true))
        #expect(terminal == 1 && said == [ValueSource.terminal] && link.all.count == 1)
        let (empty, _, nothing) = try run(["write", "save_secret", piped], link, input: .none)
        #expect(empty == 1 && nothing == [ValueSource.emptyInput] && link.all.count == 1)
        let (refused, _, words) = try run(["call", "save_secret", piped], link,
                                          input: FakeInput(Array(exampleSecretValue.utf8)).input())
        #expect(refused == 1 && words == ["save_secret writes, so founderizer-cli call does not take it: run "
                                          + "founderizer-cli write save_secret '<json object>'. The owner's client "
                                          + "asks before each write."])
        #expect(link.all.count == 1)
    }

    /// **A read of a save's state reads no file and not the standard input**, with `write` and in the MCP form: it
    /// sends the id alone, with no value part. `from` clipboard reads nothing in the program either: the app reads
    /// the clipboard itself.
    @Test func aStateReadReadsNoFileAndNoStandardInput() throws {
        let looked = LookedInput()
        let link = ValueLink(.answer(.result(Self.doneAnswer)))
        let state: [String: JSONValue] = ["request_id": .string(SaveSecretSample.id)]
        let (status, out, said) = try run(["write", "save_secret", JSONValue.object(state).dumps()], link,
                                          input: looked.input)
        #expect(status == 0 && said.isEmpty && JSONValue.parse(out.joined()) == Self.doneAnswer)
        #expect(link.all.count == 1 && link.all.first?.0.fields == state)
        #expect(link.all.first?.1 == nil && link.all.first?.0.valueBytes == nil)
        // An id in capitals, as `uuidgen` writes it, is a read too: the program sends it in lower case.
        let lettered = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeffff"
        _ = try run(["write", "save_secret", JSONValue.object(["request_id": .string(lettered.uppercased())]).dumps()],
                    link, input: looked.input)
        #expect(link.all.count == 2 && link.all.last?.0.fields == ["request_id": .string(lettered)])
        #expect(link.all.last?.1 == nil)
        // The clipboard: the fields and the made id, and no value part.
        _ = try run(["write", "save_secret", JSONValue.object(with(["from": .string("clipboard")])).dumps()], link,
                    input: looked.input)
        #expect(link.all.count == 3 && link.all.last?.1 == nil && link.all.last?.0.valueBytes == nil)
        #expect(link.all.last?.0.fields["from"] == .string("clipboard"))
        // The MCP form takes both, and reads nothing either.
        let lines = Lines()
        let mcp = OwnerMCP(tools: OwnerTools(table: Fixture.table, context: context(link, input: looked.input)),
                           version: "0.1.0", sink: { lines.add($0) })
        for (number, fields) in [state, with(["from": .string("clipboard")])].enumerated() {
            mcp.take(line: JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .int(Int64(number + 1)), "method": .string("tools/call"),
                "params": .object(["name": .string("save_secret"), "arguments": .object(fields)]),
            ]).dumps())
        }
        mcp.finish()
        let answers = lines.wait(for: 2)
        #expect(answers.count == 2 && answers.allSatisfy { $0["result"]?["isError"] == .bool(false) })
        #expect(link.all.count == 5 && link.all.suffix(2).allSatisfy { $0.1 == nil })
        #expect(link.all[3].0.fields == state)
        #expect(looked.count == 0)
        // A file that a state read names is not opened: with a path the call is no read of a state, and the
        // program refuses it before any read. The file is a folder here, which a read would refuse in other words.
        let (refused, _, words) = try run(["write", "save_secret",
                                           JSONValue.object(state.merging(["path": .string(home.path)]) { $1 }).dumps()],
                                          link, input: looked.input)
        #expect(refused == 1 && words == [SaveSecret.kindWord] && link.all.count == 5 && looked.count == 0)
    }

    /// **The MCP form lists the tool and refuses `from` stdin**, whose standard input carries the protocol: nothing
    /// is read and nothing is sent. A file goes in the MCP form.
    @Test func theMCPFormListsItAndRefusesStdin() throws {
        let looked = LookedInput()
        let link = ValueLink(.answer(.result(Self.doneAnswer)))
        let lines = Lines()
        let place = valueFile()
        let mcp = OwnerMCP(tools: OwnerTools(table: Fixture.table, context: context(link, input: looked.input)),
                           version: "0.1.0", sink: { lines.add($0) })
        mcp.take(line: #"{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}"#)
        mcp.take(line: JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .int(2), "method": .string("tools/call"),
            "params": .object(["name": .string("save_secret"), "arguments": .object(with(["from": .string("stdin")]))]),
        ]).dumps())
        mcp.take(line: JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .int(3), "method": .string("tools/call"),
            "params": .object(["name": .string("save_secret"),
                               "arguments": .object(with(["from": .string("file"), "path": .string(place)]))]),
        ]).dumps())
        mcp.finish()
        let said = lines.wait(for: 3)
        let listed = try #require(said.first { $0["id"] == .int(1) }?["result"]?["tools"]?.array)
        let tool = try #require(listed.first { $0["name"] == .string("save_secret") })
        #expect(tool["annotations"]?["readOnlyHint"] == .bool(false))
        #expect(tool["inputSchema"]?["required"] == nil)
        let stdin = try #require(said.first { $0["id"] == .int(2) }?["result"])
        #expect(stdin["isError"] == .bool(true))
        #expect(stdin["content"]?.array?.first?["text"] == .string(SaveSecret.stdinInMCP))
        let file = try #require(said.first { $0["id"] == .int(3) }?["result"])
        #expect(file["isError"] == .bool(false))
        #expect(link.all.count == 1 && link.all.first?.0.fields["from"] == .string("file"))
        #expect(link.all.first?.1 == Data((exampleSecretValue + "\n").utf8))
        #expect(looked.count == 0)
    }

    /// **A lost answer gives the id only when the program made it.** The request went out and no answer came: the
    /// save may have begun. A caller that gave no id cannot ask for it again without the id, so the words hold the
    /// id that the program made and sent; a caller that gave the id has it, and the words hold none. An answer of
    /// the app goes back as it is: the program adds nothing to it and searches nothing in it.
    @Test func aLostAnswerGivesTheIdOnlyWhenTheProgramMadeIt() throws {
        let place = valueFile()
        let fromFile = with(["from": .string("file"), "path": .string(place)])
        for words in [ChannelClient.noAnswer, ChannelClient.closedNoAnswer, ChannelClient.unreadable] {
            let link = ValueLink(.failed(words))
            let tools = OwnerTools(table: Fixture.table, context: context(link))
            // No id given: the program made one, sent it, and says it.
            let (text, isError) = tools.call("save_secret", .object(fromFile))
            let made = try #require(link.all.last?.0.fields["request_id"]?.string)
            #expect(isError && LinkWork.isID(made))
            #expect(text == SaveSecret.notKnownHereWithID(made))
            #expect(text.components(separatedBy: made).count == 2 && text.hasPrefix(SaveSecret.notKnownHere))
            // The id given: the words hold no id.
            let given = fromFile.merging(["request_id": .string(SaveSecretSample.id)]) { $1 }
            let (plain, failed) = tools.call("save_secret", .object(given))
            #expect(failed && plain == SaveSecret.notKnownHere && !plain.contains(SaveSecretSample.id))
            #expect(link.all.last?.0.fields["request_id"] == .string(SaveSecretSample.id))
            // A read of a state has words of its own (`aLostAnswerToAReadOfAStateHasItsOwnWords`): never a save's.
            let (read, lost) = tools.call("save_secret", .object(["request_id": .string(SaveSecretSample.id)]))
            #expect(lost && read == SaveSecret.notKnownState)
            // From the clipboard, with no id: the made one.
            let (copied, _) = tools.call("save_secret", .object(with(["from": .string("clipboard")])))
            let other = try #require(link.all.last?.0.fields["request_id"]?.string)
            #expect(copied == SaveSecret.notKnownHereWithID(other) && other != made)
            #expect(link.all.count == 4)
            for said in [text, plain, read, copied] {
                #expect(!said.contains(exampleSecretValue) && !said.contains(place) && !said.contains("EXAMPLE_API_KEY"))
            }
        }
        // An answer of the app, a result or a refusal, goes back as it is, also for a call whose id the program made.
        let reference = SaveSecretSample.reference
        for refusal in [SaveSecret.registerNotKnown(reference, id: SaveSecretSample.id),
                        SaveSecret.notInVault(reference, id: SaveSecretSample.id), SaveSecret.busy, SaveSecret.noWork] {
            let link = ValueLink(.answer(.refused(refusal)))
            let tools = OwnerTools(table: Fixture.table, context: context(link))
            #expect(tools.call("save_secret", .object(fromFile)) == (refusal, true))
        }
        let running = JSONValue.object(["request_id": .string(SaveSecretSample.id), "state": .string("running"),
                                        "stage": .string("storing")])
        let took = OwnerTools(table: Fixture.table, context: context(ValueLink(.answer(.result(running)))))
        #expect(took.call("save_secret", .object(fromFile)) == (running.dumps(indent: 1), false))
        // A failure before anything went out keeps the link's own words: nothing was sent, so nothing began.
        let unreached = OwnerTools(table: Fixture.table,
                                   context: context(ValueLink(.failed("This program cannot make a local socket."))))
        #expect(unreached.call("save_secret", .object(fromFile)) == ("This program cannot make a local socket.", true))
        let notRunning = OwnerTools(table: Fixture.table, context: context(ValueLink(.nothingListens)))
        #expect(notRunning.call("save_secret", .object(fromFile)) == (AppLink.notStarted, true))
    }

    /// **A lost answer to a READ of a save's state has its own words.** A read (a call with only `request_id`)
    /// begins no save and reads no clipboard, so the words of a save's lost answer would be untrue of it: "the
    /// outcome of this save is not known", macOS's question, and "a save that began goes on". The read's words say
    /// that the state was not read, that nothing was changed, and to read again. A lost answer to a save, with a
    /// given id or a made one, gets the other words, and never these. The sentence is held word for word.
    @Test func aLostAnswerToAReadOfAStateHasItsOwnWords() throws {
        let words = "The Founderizer app did not answer in time, or the link ended, so the state of this save was not "
            + "read. Nothing was changed. Call save_secret again with only this request_id."
        #expect(SaveSecret.notKnownState == words)
        let id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeffff"
        let place = valueFile()
        for failure in [ChannelClient.noAnswer, ChannelClient.closedNoAnswer, ChannelClient.unreadable] {
            let link = ValueLink(.failed(failure))
            let tools = OwnerTools(table: Fixture.table, context: context(link))
            // The read, in each form that is one: the id alone, in capitals, and with fields of null.
            let reads: [[String: JSONValue]] = [["request_id": .string(id)], ["request_id": .string(id.uppercased())],
                                                ["request_id": .string(id), "kind": .null, "from": .null]]
            for fields in reads {
                #expect(tools.call("save_secret", .object(fields)) == (words, true), "\(fields)")
                #expect(link.all.last?.0.fields == ["request_id": .string(id)] && link.all.last?.1 == nil)
            }
            // A save: the words of a save, with the given id or with the made one, from each source.
            for from in ["file", "clipboard"] {
                var save = with(["from": .string(from)])
                if from == "file" { save["path"] = .string(place) }
                let (made, _) = tools.call("save_secret", .object(save))
                let sent = try #require(link.all.last?.0.fields["request_id"]?.string)
                #expect(made == SaveSecret.notKnownHereWithID(sent) && made != words, "\(from)")
                save["request_id"] = .string(id)
                #expect(tools.call("save_secret", .object(save)) == (SaveSecret.notKnownHere, true), "\(from)")
            }
            #expect(link.all.count == 7)
        }
        // The words say nothing of a save that may have begun, and they hold no id: the caller gave it.
        for word in ["not known", "Allow Paste", "pasteboard", "clipboard", "goes on", "made twice", "in the same way"] {
            #expect(!words.contains(word), "\(word)")
        }
        #expect(words.range(of: "[0-9a-f]{8}-[0-9a-f]{4}", options: .regularExpression) == nil)
        #expect(words.contains("Nothing was changed.") && words.hasSuffix("with only this request_id."))
        #expect(words != SaveSecret.notKnownHere && !SaveSecret.notKnownHere.contains("was not read"))
        // An answer of the app to a read goes back as it is, and a failure before the send keeps the link's words.
        let answered = OwnerTools(table: Fixture.table, context: context(ValueLink(.answer(.refused(SaveSecret.noWork)))))
        #expect(answered.call("save_secret", .object(["request_id": .string(id)])) == (SaveSecret.noWork, true))
        let notRunning = OwnerTools(table: Fixture.table, context: context(ValueLink(.nothingListens)))
        #expect(notRunning.call("save_secret", .object(["request_id": .string(id)])) == (AppLink.notStarted, true))
        // The other link tools keep their own words: these are of this tool's read alone.
        #expect(!OwnerLinkTools.names.map(OwnerLinkTools.notKnownHere).contains(words))
    }

    /// **Each link tool has its own words for a lost answer**, and no tool gets another one's. A name with no case
    /// gets words that name no tool and no effect. The words that a caller gives for one call (`notKnown`) go only
    /// to a link write: a setup tool keeps the link's own words.
    @Test func eachLinkToolHasItsOwnWordsForALostAnswer() {
        #expect(OwnerLinkTools.notKnownHere(SaveBotToken.name) == SaveBotToken.notKnownHere)
        #expect(OwnerLinkTools.notKnownHere(PrepareReport.name) == PrepareReport.notKnownHere)
        #expect(OwnerLinkTools.notKnownHere(SaveSecret.name) == SaveSecret.notKnownHere)
        let own = OwnerLinkTools.names.map(OwnerLinkTools.notKnownHere)
        #expect(Set(own).count == OwnerLinkTools.names.count)
        #expect(!own.contains(OwnerLinkTools.notKnownOther))
        for (name, words) in zip(OwnerLinkTools.names, own) {
            #expect(words.contains("not known"), "\(name)")
            // No tool's words name another tool.
            for other in OwnerLinkTools.names where other != name { #expect(!words.contains(other), "\(name): \(other)") }
        }
        // A name with no case: not the bot token's words, and nothing of any tool.
        for name in ["save_something", "setup_state", "", "Save_Secret"] {
            #expect(OwnerLinkTools.notKnownHere(name) == OwnerLinkTools.notKnownOther, "\(name)")
        }
        let other = OwnerLinkTools.notKnownOther
        #expect(other.contains("not known"))
        for word in OwnerLinkTools.names + ["token", "Discord", "report", "secret", "clipboard", "pasteboard", "hub"] {
            #expect(!other.contains(word), "\(word)")
        }
        // The link gives each tool its own words, and the caller's words for one call only to a link write.
        for words in [ChannelClient.noAnswer, ChannelClient.closedNoAnswer, ChannelClient.unreadable] {
            let link = AppLink(exchange: { _, _ in .failed(words) }, start: { false }, pause: {}, tries: 0)
            for name in OwnerLinkTools.names {
                #expect(link.call(tool: name, fields: [:]) == (OwnerLinkTools.notKnownHere(name), true), "\(name)")
                #expect(link.call(tool: name, fields: [:], notKnown: "words of this call") == ("words of this call", true))
            }
            for name in OwnerSetupTools.names {
                #expect(link.call(tool: name, fields: [:], notKnown: "words of this call") == (words, true), "\(name)")
            }
        }
        // The caller's words are for a lost answer only: an answer, and a failure before the send, keep their own.
        let refused = AppLink(exchange: { _, _ in .answer(.refused("the app's own words")) }, start: { false },
                              pause: {}, tries: 0)
        #expect(refused.call(tool: SaveSecret.name, fields: [:], notKnown: "words of this call")
                == ("the app's own words", true))
        let unreached = AppLink(exchange: { _, _ in .failed("This program cannot make a local socket.") },
                                start: { false }, pause: {}, tries: 0)
        #expect(unreached.call(tool: SaveSecret.name, fields: [:], notKnown: "words of this call")
                == ("This program cannot make a local socket.", true))
    }

    /// **Each link tool has its own part in the program**, by its name: none falls into another tool's plan. With
    /// no field at all, each one's refusal is its own tool's sentence, and nothing is sent.
    @Test func eachLinkToolHasItsOwnPartInTheProgram() {
        let link = ValueLink()
        let tools = OwnerTools(table: Fixture.table, context: context(link))
        #expect(tools.call(SaveBotToken.name, .object([:])) == (SaveBotToken.account, true))
        #expect(tools.call(PrepareReport.name, .object([:])) == (PrepareReport.textWord, true))
        #expect(tools.call(SaveSecret.name, .object([:])) == (SaveSecret.kindWord, true))
        // A field that only the bot token's tool takes is no field of save_secret, and the other way round.
        #expect(tools.call(SaveSecret.name, .object(["account": .string("discord-example")])) == (SaveSecret.only, true))
        #expect(tools.call(SaveBotToken.name, .object(["account": .string("discord-example"),
                                                       "kind": .string("api_key")])) == (SaveBotToken.only, true))
        for name in OwnerLinkTools.names {
            let (words, isError) = tools.call(name, .object([:]))
            #expect(isError && !words.contains("has no part in this program"), "\(name)")
            #expect(tools.call(name, .array([])) == ("\(name) takes one JSON object of its fields. Nothing was sent.", true))
        }
        #expect(link.all.isEmpty)
    }

    /// **The two tools that take a value read their source in one way**: for each path that is no file to read, a
    /// pipe that is a terminal and a pipe with nothing, `save_secret` says the sentence that `save_bot_token` says,
    /// and none quotes anything of the request.
    @Test func theSourceIsReadAsTheBotTokensIs() throws {
        let link = ValueLink(.answer(.refused("never asked")))
        let markerFolder = home.appendingPathComponent(marker, isDirectory: true)
        try FileManager.default.createDirectory(at: markerFolder, withIntermediateDirectories: true)
        let emptyFile = home.appendingPathComponent(marker + ".txt").path
        FileManager.default.createFile(atPath: emptyFile, contents: Data())
        let linked = home.appendingPathComponent(marker + "-link").path
        try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: valueFile())
        let large = home.appendingPathComponent(marker + "-large.txt").path
        FileManager.default.createFile(atPath: large, contents: Data(repeating: 0x61, count: OwnerChannel.valueMax + 1))
        let paths: [(String, String)] = [(marker, ValueSource.missing), (markerFolder.path, ValueSource.notRegular),
                                         (emptyFile, ValueSource.emptyFile), (linked, ValueSource.isLink),
                                         (large, ValueSource.largeFile)]
        for input in [StandardInput.none, FakeInput([0x61]).input(terminal: true)] {
            let tools = OwnerTools(table: Fixture.table, context: context(link, input: input))
            tools.standardInputFree = true
            for (path, expected) in paths {
                let mine = tools.call("save_secret", .object(with(["from": .string("file"), "path": .string(path)])))
                let theirs = tools.call("save_bot_token", .object(["account": .string("discord-example"),
                                                                   "from": .string("file"), "path": .string(path)]))
                #expect(mine == (expected, true) && theirs == (expected, true), "\(expected)")
                #expect(!mine.text.contains(marker))
            }
            let nul = tools.call("save_secret", .object(with(["from": .string("file"), "path": .string(marker + "\u{0}")])))
            #expect(nul == tools.call("save_bot_token", .object(["account": .string("discord-example"),
                                                                 "from": .string("file"),
                                                                 "path": .string(marker + "\u{0}")])))
            #expect(nul.isError && !nul.text.contains(marker))
            let piped = tools.call("save_secret", .object(with(["from": .string("stdin")])))
            #expect(piped == tools.call("save_bot_token", .object(["account": .string("discord-example"),
                                                                   "from": .string("stdin")])))
            #expect(piped.isError && [ValueSource.terminal, ValueSource.emptyInput].contains(piped.text))
        }
        // In the MCP form each tool has its own sentence for stdin, and the two are the same but for the word.
        let closed = OwnerTools(table: Fixture.table, context: context(link, input: FakeInput([0x61]).input()))
        #expect(closed.call("save_secret", .object(with(["from": .string("stdin")]))) == (SaveSecret.stdinInMCP, true))
        #expect(closed.call("save_bot_token", .object(["account": .string("discord-example"), "from": .string("stdin")]))
                == (SaveBotToken.stdinInMCP, true))
        #expect(link.all.isEmpty)
    }
}

/// **The whole way**: the program's tool, its file read, the real exchange on a socket of the test's own, the board
/// as `LinkTools.add` fills it (one table of work for the tool), and the tool's logic with a stand-in desk.
final class OwnerSaveSecretLinkTests {
    let home = Fixture.home()
    let folder: URL
    let path: String

    init() {
        // Short: a local socket's path takes at most 104 bytes.
        folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fzs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        path = folder.appendingPathComponent("app.sock").path
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: folder)
    }

    /// How each call of the tool ended, as the board's entry saw it: the call's answer, and whether the call's own
    /// task was cancelled then (the listener cancels it when the call's connection ends).
    @MainActor
    final class CallEnds {
        var all: [(answer: OwnerChannel.Answer, cancelled: Bool)] = []
    }

    /// **The app's side**: a board with the tool on it, as `LinkTools.add` puts it there (the set `owner`, a value
    /// part that the tool decides on, one table of work), and the stand-in for the app's engine. Two things more
    /// than the app has, for a test to look at: a weak look at each box that a call makes (when did the value's
    /// holder go), and the end of each call (its answer, and whether its task was cancelled).
    private func wired() async throws -> (board: SetupBoard, desk: StandInVaultDesk, ends: CallEnds) {
        try await MainActor.run {
            let app = try StandInVaultDesk()
            let ends = CallEnds()
            let board = SetupBoard(read: { OwnerSetupBoardTests.facts() }, show: { _, _ in nil })
            let desk = app.desk, work = app.table
            let added = board.add(set: OwnerSetupTools.set, tool: SaveSecret.name, value: .optional) { fields, value in
                let answer = await SaveSecret.answer(fields: fields, value: value, desk: desk, work: work) { box in
                    let look = StandInVaultDesk.Look()
                    look.box = box
                    app.looks.append(look)
                }
                ends.all.append((answer, Task.isCancelled))
                return answer
            }
            #expect(added)
            return (board, app, ends)
        }
    }

    /// Each call made a box for its value, or none, and nothing holds one any more.
    private func boxesGone(_ app: StandInVaultDesk) async -> Bool {
        await comes { !app.looks.isEmpty && app.looks.allSatisfy { $0.box == nil } }
    }

    private func listener(_ board: SetupBoard) -> ChannelListener {
        ChannelListener(path: path, check: StandInCheck(takes: true)) { request, value in
            await board.answer(request, value: value)
        }
    }

    /// The program, with a link to the test's own socket.
    private func tools() -> OwnerTools {
        let path = path
        let appLink = AppLink(exchange: { request, value in
            ChannelClient.exchange(path: path, request: request, value: value, check: StandInCheck(takes: true))
        }, start: { false }, pause: {}, tries: 0)
        let context = OwnerContext(hubSetting: { nil }, transport: Fixture.transport(), home: home,
                                   userAgent: "founderizer-cli/test", ownBuild: nil, startedBuild: { nil },
                                   clientLabel: { "founderizer-cli/1/test" }, appLink: appLink)
        return OwnerTools(table: Fixture.table, context: context)
    }

    /// Waits for a fact of another thread, by a count of looks (the patience of the link's own tests).
    private func comes(_ done: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await MainActor.run(body: done) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await MainActor.run(body: done)
    }

    /// What the stand-in's hub and vault steps were asked, as plain values.
    private struct Sent: Sendable {
        var references: [String]
        var titles: [String]
        var addresses: [String?]
        var items: [[String: String]]
        var intakes: [String]
        var refreshes: Int
        var clipboardReads: Int
    }

    private func sent(_ app: StandInVaultDesk) async -> Sent {
        await MainActor.run {
            Sent(references: app.registers.map(\.reference), titles: app.registers.map(\.title),
                 addresses: app.registers.map(\.address), items: app.registers.map(\.item),
                 intakes: app.intakes.map(\.reference), refreshes: app.refreshes, clipboardReads: app.clipboardReads)
        }
    }

    /// **A save goes the whole way, from a file**: the program makes the id and reads the file, the link carries
    /// the fields and the value part, the app takes the one line end off, seals, registers the entry with a key's
    /// address, and passes the sealed copy on. The answer has the id, the reference, the title and the kind, and
    /// nothing of the value. A read of the state and the same call again change nothing and make nothing twice.
    @Test func aSaveGoesTheWholeWay() async throws {
        let (board, app, _) = try await wired()
        let link = listener(board)
        defer { link.stop() }
        #expect(link.start() == .listening)
        let tools = tools()
        // A file as a real one is: the value and one line end.
        let file = home.appendingPathComponent("example-key.txt").path
        FileManager.default.createFile(atPath: file, contents: Data((exampleSecretValue + "\n").utf8))
        let key: [String: JSONValue] = ["kind": .string("api_key"), "env": .string("EXAMPLE_API_KEY"),
                                        "url": .string("https://api.example.com/v1"), "from": .string("file"),
                                        "path": .string(file)]
        let (text, isError) = await off { tools.call("save_secret", .object(key)) }
        #expect(!isError, "\(text)")
        let answer = try #require(JSONValue.parse(text)?.object)
        let id = try #require(answer["request_id"]?.string)
        let reference = try #require(answer["reference"]?.string)
        #expect(LinkWork.isID(id) && LoginSecret.isReference(reference))
        let done: [String: JSONValue] = ["request_id": .string(id), "state": .string("done"),
                                         "reference": .string(reference), "title": .string("EXAMPLE_API_KEY"),
                                         "kind": .string("api_key")]
        #expect(answer == done)
        #expect(!text.contains(exampleSecretValue) && !text.contains(file))
        var seen = await sent(app)
        #expect(seen.references == [reference] && seen.titles == ["EXAMPLE_API_KEY"])
        // The key's address: the scheme and the host, with no path. The whole address is only in the item.
        #expect(seen.addresses == ["https://api.example.com"])
        // The item holds the value with no line end: the app took off the file's one line end, and nothing else.
        #expect(seen.items == [["username": "", "password": exampleSecretValue, "url": "https://api.example.com/v1"]])
        #expect(seen.intakes == [reference] && seen.refreshes == 1 && seen.clipboardReads == 0)

        // A read of the state, with only the id that the answer named: the same answer, and nothing new.
        let (state, stateFailed) = await off { tools.call("save_secret", .object(["request_id": .string(id)])) }
        #expect(!stateFailed && JSONValue.parse(state)?.object == done)
        // The same call again with that id: it joins the save that is done, and nothing is made twice.
        let (again, againFailed) = await off {
            tools.call("save_secret", .object(key.merging(["request_id": .string(id)]) { $1 }))
        }
        #expect(!againFailed && JSONValue.parse(again)?.object == done)
        // The same id with other fields is another save: refused, and nothing changes.
        let (other, otherFailed) = await off {
            tools.call("save_secret", .object(key.merging(["request_id": .string(id),
                                                           "env": .string("OTHER_API_KEY")]) { $1 }))
        }
        #expect(otherFailed && other == SaveSecret.otherFields)
        seen = await sent(app)
        #expect(seen.references == [reference] && seen.intakes == [reference])

        // A login the whole way: its title is the host and the user name, and no address goes with its entry.
        let login: [String: JSONValue] = ["kind": .string("login"), "url": .string("https://shop.example.com/login?next=1"),
                                          "username": .string("owner@example.com"), "from": .string("file"),
                                          "path": .string(file)]
        let (second, secondFailed) = await off { tools.call("save_secret", .object(login)) }
        #expect(!secondFailed, "\(second)")
        let saved = try #require(JSONValue.parse(second)?.object)
        #expect(saved["state"] == .string("done") && saved["kind"] == .string("login"))
        #expect(saved["title"] == .string("shop.example.com · owner@example.com"))
        #expect(saved["request_id"] != .string(id) && saved["reference"] != .string(reference))
        seen = await sent(app)
        #expect(seen.addresses == ["https://api.example.com", nil])
        #expect(seen.items.last == ["username": "owner@example.com", "password": exampleSecretValue,
                                    "url": "https://shop.example.com/login?next=1"])
        #expect(seen.references.count == 2 && seen.intakes == seen.references)

        // A name that the list has now is refused, the whole way, and nothing is sent.
        let (held, heldFailed) = await off { tools.call("save_secret", .object(key)) }
        #expect(heldFailed && held == SaveSecret.held)
        // A file whose text is no value: refused by the app, with nothing of the text in the words. Two line ends
        // are one more than the app takes off.
        FileManager.default.createFile(atPath: file, contents: Data((marker + "-0123\n\n").utf8))
        let fresh = key.merging(["env": .string("THIRD_API_KEY")]) { $1 }
        let (refused, failed) = await off { tools.call("save_secret", .object(fresh)) }
        #expect(failed && refused == SaveSecret.notAValue && !refused.contains(marker))
        // A wrong field never reaches the app.
        let (wrong, wrongFailed) = await off {
            tools.call("save_secret", .object(fresh.merging(["env": .string("third_api_key")]) { $1 }))
        }
        #expect(wrongFailed && wrong == SaveSecret.envWord)
        seen = await sent(app)
        #expect(seen.references.count == 2 && seen.intakes.count == 2 && seen.clipboardReads == 0)
        // Nothing holds a value any more: the box of each save went with its work, and each refused one at once.
        #expect(await boxesGone(app))
    }

    /// **A client that goes after its line leaves the save running.** The caller's connection ends while the save
    /// stands between its two sends: the listener ends the call, and the work, which is the table's, goes on. A
    /// later read of the id says `running`, and then `done`, with one entry and one sealed copy: nothing is lost
    /// half way and nothing is made twice. (A read's work does end with its client:
    /// `OwnerChannelTests.aClientThatGoesAfterItsLineEndsItsWork`.)
    ///
    /// **The work is not the call's, and the test holds the two apart.** The call's own task was cancelled when
    /// its client went: the board's entry saw that cancel as the call ended, with the answer that the save runs.
    /// Each step of the work ran in a task that saw no cancel, also the vault's step, which went on only after
    /// the client had gone. A run that took the call's cancel would record one at that step, and this test fails.
    /// The steps of the call itself (the key's read and the room, before the save begins) run in the call's task
    /// and can see its cancel by design: they are the steps before the first `register`, and no part of
    /// `workSteps`. Here they ran before the client went.
    @Test func aClientThatGoesAfterItsLineLeavesTheSaveRunning() async throws {
        let (board, app, ends) = try await wired()
        await MainActor.run { app.holdAt = ["intake"] }
        let link = listener(board)
        defer { link.stop() }
        #expect(link.start() == .listening)
        let id = SaveSecretSample.id
        // A client of its own: the request line and the value part, as the program sends them. It reads no answer.
        let value = Data((exampleSecretValue + "\n").utf8)
        let request = OwnerChannel.Request(set: "owner", tool: SaveSecret.name,
                                           fields: ["request_id": .string(id), "kind": .string("api_key"),
                                                    "env": .string("EXAMPLE_API_KEY"), "from": .string("file")],
                                           valueBytes: value.count)
        let socket = OwnerChannel.newSocket()
        try #require(socket >= 0)
        try #require(OwnerChannel.connect(socket, to: path) == 0)
        let wire = request.line + value
        #expect(wire.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) } == wire.count)
        // The save began: the hub has the entry, and the vault's step waits.
        #expect(await comes { app.holds("intake") == 1 })
        close(socket)
        // The listener saw the close and ended the call: its place is free.
        #expect(await comes { link.openCount == 0 })
        // The call itself ended by its cancel, and its answer, which nobody read, said that the save runs.
        let stillRuns: JSONValue = .object(["request_id": .string(id), "state": .string("running"),
                                            "stage": .string("storing")])
        #expect(await comes { ends.all.count == 1 })
        let call = await MainActor.run { ends.all.first }
        #expect(call?.cancelled == true && call?.answer == .result(stillRuns))
        // The work stands where it stood: its step at the vault still waits, and nothing ended it.
        #expect(await MainActor.run { app.holds("intake") == 1 && app.steps.map(\.name) == ["sealKey", "room", "register"] })
        let tools = tools()
        let read: JSONValue = .object(["request_id": .string(id)])
        let (running, failed) = await off { tools.call("save_secret", read) }
        #expect(!failed, "\(running)")
        #expect(JSONValue.parse(running) == stillRuns)
        // The vault answers: the work, which no call waits for now, ends by itself.
        await MainActor.run { app.open("intake") }
        var last = running
        for _ in 0..<500 {
            let (text, isError) = await off { tools.call("save_secret", read) }
            #expect(!isError, "\(text)")
            last = text
            if isError || JSONValue.parse(text)?["state"] != .string("running") { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let seen = await sent(app)
        let reference = try #require(seen.references.first)
        #expect(JSONValue.parse(last) == .object(["request_id": .string(id), "state": .string("done"),
                                                  "reference": .string(reference),
                                                  "title": .string("EXAMPLE_API_KEY"), "kind": .string("api_key")]))
        #expect(seen.references == [reference] && seen.intakes == [reference] && seen.refreshes == 1)
        #expect(seen.items == [["username": "", "password": exampleSecretValue]])
        #expect(!last.contains(exampleSecretValue))
        // **No step of the work saw a cancel**: the entry's step, before the client went, and the vault's step,
        // which went on after the call had ended by its cancel. The two before them are the call's own checks.
        let steps = await MainActor.run { (all: app.steps, work: app.workSteps) }
        #expect(steps.all.map(\.name) == ["sealKey", "room", "register", "intake"])
        #expect(steps.work.map(\.name) == ["register", "intake"])
        #expect(steps.work.allSatisfy { !$0.cancelled }, "\(steps.work)")
        // Each later call was a read of the state with a caller that waited: none ended by a cancel.
        let later = await MainActor.run { ends.all.dropFirst().map { $0.cancelled } }
        #expect(!later.isEmpty && !later.contains(true))
        // Nothing holds the value any more: the work's box went with its closure.
        #expect(await boxesGone(app))
    }
}
