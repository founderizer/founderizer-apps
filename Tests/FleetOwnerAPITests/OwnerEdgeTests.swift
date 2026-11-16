import Darwin
import Foundation
import Testing
@testable import FleetOwnerAPI

/// What a hub in trouble, a broken network, an odd request and an updated app do to the program.
final class OwnerEdgeTests {
    let home = Fixture.home()
    deinit { try? FileManager.default.removeItem(at: home) }

    // ------------------------------------------------------------ a broken network

    @Test func onlyAnErrorWithNoConnectionIsDidNotAnswer() {
        for code in SessionTransport.noConnection {
            guard case .unreachable = SessionTransport.failure(URLError(code)) else {
                Issue.record("\(code) is not 'did not answer'"); continue
            }
        }
        for code: URLError.Code in [.timedOut, .networkConnectionLost, .badServerResponse, .cancelled, .unknown] {
            guard case .lost = SessionTransport.failure(URLError(code)) else {
                Issue.record("\(code) is not 'lost'"); continue
            }
        }
        guard case .lost = SessionTransport.failure(CocoaError(.fileReadUnknown)) else {
            Issue.record("an error of another kind is not 'lost'"); return
        }
    }

    @Test func aLostAnswerSaysTheRequestCanHaveArrived() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        hub.failWith = { $0.method == "POST" ? .networkConnectionLost : nil }
        let tools = Fixture.tools(hub, home: home)
        let lost = try #require(tools.refused("take_release"))
        #expect(lost.hasPrefix("The call to the hub at \(hub.base) was lost: "))
        #expect(lost.hasSuffix("The request can have arrived: read the fleet before you send it again."))
        hub.failWith = { $0.method == "POST" ? .timedOut : nil }
        #expect(tools.refused("take_release")?.contains("The request can have arrived") == true)
        hub.failWith = { _ in .cannotConnectToHost }
        let none = try #require(Fixture.tools(hub, home: home).refused("fleet_overview"))
        #expect(none.hasPrefix("The hub at \(hub.base) did not answer ("))
        #expect(none.hasSuffix("Check that it runs and that this Mac is on the fleet's private network."))
    }

    /// `share_resource` of a secret whose read of the vault gets no answer sends nothing: the branch that the parity
    /// fixture cannot hold, because its stand-in hub always answers.
    @Test func aStandingForASecretWhoseReadOfTheVaultGetsNoAnswerSendsNothing() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        hub.failWith = { $0.path == "/ui/vault" ? .cannotConnectToHost : nil }
        let tools = Fixture.tools(hub, home: home)
        let none = try #require(tools.refused("share_resource", ["resource": .string("secret:bws://example-1"),
                                                                 "max": .string("use")]))
        #expect(none.hasPrefix("The hub at \(hub.base) did not answer ("))
        #expect(hub.seen.map(\.path).filter { $0 != "/ui/state" } == ["/ui/vault"])
        hub.failWith = { $0.path == "/ui/vault" ? .networkConnectionLost : nil }
        let lost = try #require(tools.refused("share_resource", ["resource": .string("secret:bws://example-1"),
                                                                 "max": .string("use")]))
        #expect(lost.hasPrefix("The call to the hub at \(hub.base) was lost")
                || lost.hasPrefix("The hub at \(hub.base) did not answer"))
        #expect(!hub.seen.contains { $0.method == "POST" || $0.path == "/ui/team" })
    }

    // ------------------------------------------------------------ a hub in trouble

    @Test func aHubInTroubleIsSaidInItsOwnWords() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        let tools = Fixture.tools(hub, home: home)
        hub.raw = { $0.path == "/ui/health" ? (200, "text/plain", Data("all well".utf8)) : nil }
        #expect(tools.call("fleet_read", .object(["page": .string("health")])) == (OwnerTools.dataMark + "\nnull", false))
        hub.raw = { $0.path == "/ui/health" ? (200, "application/json", Data(count: SessionTransport.readMax + 1)) : nil }
        #expect(tools.refused("fleet_read", ["page": .string("health")]) == "The hub's answer is larger than this server reads.")
        hub.raw = { $0.method == "POST" ? (502, "text/html", Data("<html>Bad gateway</html>".utf8)) : nil }
        #expect(tools.refused("take_release") == "The hub refused the update (502): <html>Bad gateway</html>")
    }

    @Test func aSecond409AboutTheGenerationIsGivenBackAndNotSentAThirdTime() {
        let hub = StandInHub(features: Fixture.everyFeature)
        hub.answer = { $0.method == "POST" ? (409, .object(["error": .string("hub generation changed; refresh state")])) : nil }
        let tools = Fixture.tools(hub, home: home)
        #expect(tools.refused("take_release") == "The hub refused the update (409): hub generation changed; refresh state")
        #expect(hub.seen.filter { $0.method == "POST" }.count == 2)
    }

    @Test func aTeamReadWithNoSHA256IsNotSent() {
        let hub = StandInHub(features: Fixture.everyFeature)
        hub.answer = { $0.path == "/ui/team" ? (200, .object(["lines": .array([])])) : nil }
        let tools = Fixture.tools(hub, home: home)
        #expect(tools.refused("activate_agent", ["agent": .string("worker-1"), "active": .bool(true)])
                == "activate_agent could not be sent: 'sha256'")
        #expect(hub.seen.allSatisfy { $0.method == "GET" })
    }

    // ------------------------------------------------------------ odd requests

    @Test func aPlainToolWhoseRequestIDIsNotTheAgentsMakesItsOwn() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        let table = Fixture.table(changing: "check_releases") {
            OwnerTable.Tool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema,
                            annotations: $0.annotations, kind: $0.kind, route: $0.route, fields: $0.fields, what: $0.what,
                            revisionPage: nil, requestIDFromArguments: false, feature: $0.feature)
        }
        let tools = Fixture.tools(hub, home: home, table: table)
        let given = "6f1c2a3b-0000-4000-8000-00000000000b"
        _ = try tools.json("check_releases", ["request_id": .string(given)])
        let sent = try #require(hub.seen.first { $0.method == "POST" }?.body?["request_id"]?.string)
        #expect(sent != given && UUID(uuidString: sent) != nil)
    }

    @Test func argumentsThatAreNoObjectAreRefused() {
        let hub = StandInHub(features: Fixture.everyFeature)
        let tools = Fixture.tools(hub, home: home)
        #expect(tools.call("take_release", .string("x"))
                == ("take_release could not be sent: its arguments must be an object of its fields, not \"x\".", true))
        #expect(tools.call("take_release", .array([])).isError)
        #expect(hub.seen.isEmpty)
        #expect(tools.call("check_releases", .null).isError == false)
    }

    @Test func aWholeNumberAboveInt64IsRefusedInWords() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        let tools = Fixture.tools(hub, home: home)
        for digits in ["9223372036854775808", "123456789012345678901234567890"] {
            let arguments = try #require(JSONValue.parse("{\"task\": \(digits), \"action\": \"pause\"}"))
            #expect(tools.call("control_task", arguments)
                    == ("control_task could not be sent: the whole number \(digits) is larger than this program can carry "
                        + "(9223372036854775807 at most).", true))
        }
        #expect(JSONValue.parse("9223372036854775807") == .int(Int64.max))
        #expect(JSONValue.parse("1.5") == .double(1.5))
        #expect(hub.seen.isEmpty)
    }

    /// A number with a fraction or an exponent is a float, as Python reads it, also at or above 2^64.
    @Test func aFloatAtOrAbove2To64IsAFloat() throws {
        #expect(JSONValue.parse("18446744073709551616.0") == .double(18446744073709551616.0))
        #expect(JSONValue.parse("1e20") == .double(1e20) && JSONValue.parse("-1E+20") == .double(-1e20))
        #expect(JSONValue.parse("100000000000000000000.5") == .double(1e20))
        #expect(JSONValue.parse("18446744073709551616") == .bigInt("18446744073709551616"))
        #expect(JSONValue.parse("-9223372036854775809") == .bigInt("-9223372036854775809"))
        #expect(JSONValue.parse("1E400") == .double(.infinity))
        let hub = StandInHub(features: Fixture.everyFeature)
        let tools = Fixture.tools(hub, home: home)
        let arguments = try #require(JSONValue.parse(#"{"need": 4, "choice": 18446744073709551616.0}"#))
        #expect(tools.call("answer_needs_you", arguments).isError == false)
        #expect(hub.seen.last?.body?["choice"] == .double(18446744073709551616.0))
    }

    @Test func theReaderTakesWhatPythonTakesAndNothingElse() {
        #expect(JSONValue.parse(#"{"a": 1, "a": 2}"#) == .object(["a": .int(2)]))
        #expect(JSONValue.parse(#""\ud83d\ude00 \u00e9""#) == .string("\u{1F600} \u{e9}"))
        #expect(JSONValue.parse(#""\ud800x""#) == .string("\u{FFFD}x"))
        #expect(JSONValue.parse("NaN")?.pythonText == "NaN" && JSONValue.parse("-Infinity") == .double(-.infinity))
        for bad in ["", "01", "1.", "[1,]", "{\"a\" 1}", "\"a\u{01}\"", "tru", "[1] x", "{'a': 1}", "\"\\x\""] {
            #expect(JSONValue.parse(bad) == nil, "\(bad)")
        }
        #expect(JSONValue.parse(String(repeating: "[", count: 600) + String(repeating: "]", count: 600)) == nil)
        #expect(JSONValue.parse(" [ 1 , {\"b\" : null} ] ") == .array([.int(1), .object(["b": .null])]))
    }

    @Test func aResponseOfTheClientIsNotAnswered() {
        let lines = Lines()
        let mcp = OwnerMCP(tools: Fixture.tools(nil, home: home), version: "0.1.0", sink: { lines.add($0) })
        mcp.take(line: #"{"jsonrpc": "2.0", "id": 3, "result": {}}"#)
        mcp.take(line: #"{"jsonrpc": "2.0", "id": 4, "error": {"code": -1, "message": "no"}}"#)
        mcp.take(line: #"{"jsonrpc": "2.0", "id": 5, "method": "ping"}"#)
        mcp.finish()
        let said = lines.wait(for: 1)
        #expect(said == [.object(["jsonrpc": .string("2.0"), "id": .int(5), "result": .object([:])])])
        #expect(lines.all.count == 1)
    }

    @Test func aPathPartThatIsADotOrTwoIsRefusedBeforeAnyRequest() {
        let hub = StandInHub(features: Fixture.everyFeature)
        let tools = Fixture.tools(hub, home: home)
        #expect(tools.refused("check_machine", ["agent": .string("..")])
                == "agent cannot be \"..\": a part of a route is never \".\" or \"..\".")
        #expect(tools.refused("fleet_read", ["page": .string("notes"), "agent": .string(".")])
                == "agent cannot be \".\": a part of a route is never \".\" or \"..\".")
        #expect(hub.seen.allSatisfy { $0.method == "GET" && $0.path == "/ui/state" })
    }

    @Test func aKindThatTheProgramDoesNotKnowIsALaterTool() throws {
        let url = Bundle.module.url(forResource: "owner-tools", withExtension: "json", subdirectory: "Fixtures")!
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"kind\": \"swift\"", with: "\"kind\": \"from_the_future\"")
        let table = try OwnerTable.parse(Data(text.utf8))
        #expect(table.tool("fleet_overview")?.kind == .later)
        let tools = Fixture.tools(StandInHub(features: []), home: home, table: table)
        #expect(tools.refused("fleet_overview") == "fleet_overview is not in this version of the app yet. Ask the owner "
                + "to update the Founderizer app, or to use owner_mcp.py for it.")
        #expect(!tools.listed.contains { $0.name == "fleet_overview" })
    }

    @Test func invalidRequestsGetMinus32600() {
        let lines = Lines()
        let mcp = OwnerMCP(tools: Fixture.tools(nil, home: home), version: "0.1.0", sink: { lines.add($0) })
        mcp.take(line: #"{"jsonrpc": "2.0", "id": 7}"#)
        mcp.take(line: #"{"jsonrpc": "2.0", "id": 8, "method": 5}"#)
        mcp.take(line: "[]")
        mcp.take(line: #"[{"jsonrpc": "2.0", "id": 9, "method": "ping"}, {"jsonrpc": "2.0", "id": 10, "method": "ping"}]"#)
        mcp.take(line: #"{"jsonrpc": "2.0", "method": "notifications/initialized"}"#)
        mcp.finish()
        let said = lines.wait(for: 4)
        #expect(said.count == 4)
        func invalid(_ id: JSONValue) -> JSONValue {
            .object(["jsonrpc": .string("2.0"), "id": id,
                     "error": .object(["code": .int(-32600), "message": .string("Invalid Request")])])
        }
        #expect(said.prefix(3) == [invalid(.int(7)), invalid(.int(8)), invalid(.null)])
        #expect(said.last?.array?.map { $0["id"] } == [.int(9), .int(10)])
        #expect(said.last?.array?.allSatisfy { $0["result"] == .object([:]) } == true)
    }

    // ------------------------------------------------------------ an app that was updated under the program

    private func app(_ place: String, build: Int) throws -> URL {
        let bundle = home.appendingPathComponent("\(place)/Founderizer.app", isDirectory: true)
        try? FileManager.default.removeItem(at: bundle)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": String(build)], format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try Data("program".utf8).write(to: macOS.appendingPathComponent("founderizer-cli"))
        return bundle
    }

    private func refused(own: Int, start: String) -> Bool {
        let hub = StandInHub(features: Fixture.everyFeature)
        return Fixture.tools(hub, home: home, ownBuild: own, started: { ProgramPlace.build(behind: start) })
            .refused("fleet_overview") == OwnerTools.updated
    }

    @Test func theAppWasUpdatedOnlyWhenTheStartPathLeadsToAHigherBuild() throws {
        let link = home.appendingPathComponent("link-cli").path
        let first = try app("one", build: 215)
        try FileManager.default.createSymbolicLink(atPath: link,
                                                   withDestinationPath: first.path + "/Contents/MacOS/founderizer-cli")
        #expect(!refused(own: 215, start: link))                     // the same build
        _ = try app("one", build: 216)                              // the link's app was updated
        #expect(refused(own: 215, start: link))
        #expect(!refused(own: 217, start: link))                     // an older build behind the path
        let direct = try app("two", build: 215).path + "/Contents/MacOS/founderizer-cli"
        #expect(!refused(own: 215, start: direct))
        _ = try app("two", build: 216)                              // the bundle at the direct path was replaced
        #expect(refused(own: 215, start: direct))
        try FileManager.default.removeItem(at: home.appendingPathComponent("two"))
        #expect(!refused(own: 215, start: direct))                   // a start path that is gone
        #expect(!refused(own: 215, start: home.appendingPathComponent("build/founderizer-cli").path))   // no bundle
    }

    @Test func theStartPathIsMadeAbsoluteAndNotResolved() throws {
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let program = bin.appendingPathComponent("founderizer-cli")
        try Data("#!/bin/sh\n".utf8).write(to: program)
        chmod(program.path, 0o755)
        #expect(ProgramPlace.startPath(argument: "/a/b/founderizer-cli", directory: "/x", path: nil) == "/a/b/founderizer-cli")
        #expect(ProgramPlace.startPath(argument: "b/founderizer-cli", directory: "/x", path: nil) == "/x/b/founderizer-cli")
        #expect(ProgramPlace.startPath(argument: "founderizer-cli", directory: "/x", path: "/nowhere:" + bin.path)
                == program.path)
        #expect(ProgramPlace.startPath(argument: "founderizer-cli", directory: "/x", path: "/nowhere") == nil)
    }

    // ------------------------------------------------------------ connect and the link

    @Test func connectPrintsTheLinksWholePathWhenTheLinkPointsAtTheProgram() throws {
        let bundle = try app("linked", build: 215)
        let program = URL(fileURLWithPath: try #require(
            ProgramPlace.realPath(bundle.path + "/Contents/MacOS/founderizer-cli")))
        let folder = home.appendingPathComponent(".founderizer", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("cli").path,
                                                   withDestinationPath: program.path)
        let path = OwnerCLI.connectPath(executable: program, home: home)
        #expect(path == folder.appendingPathComponent("cli").path && path.hasPrefix("/") && !path.contains("~"))
        let other = try app("other", build: 215).appendingPathComponent("Contents/MacOS/founderizer-cli")
        #expect(OwnerCLI.connectPath(executable: other, home: home) == other.path)
    }

    @Test func aFileInTheFoldersPlaceIsNeverChanged() throws {
        let bundle = try app("file", build: 215)
        let place = home.appendingPathComponent(".founderizer")
        try Data("mine".utf8).write(to: place)
        chmod(place.path, 0o644)
        #expect(CLILink.keep(bundle: bundle, home: home, signedWithDeveloperID: true, hubAddressArgument: false) == .keep)
        var info = stat()
        #expect(stat(place.path, &info) == 0 && info.st_mode & 0o777 == 0o644)
        #expect(try String(contentsOf: place, encoding: .utf8) == "mine")
    }
}
