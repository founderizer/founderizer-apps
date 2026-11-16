import Darwin
import Foundation
import Testing
@testable import FleetCore
@testable import FleetOwnerAPI

// **`grant_secret`** (`OwnerGrantSecret.swift`): the fields and their forms, the tool's words, the app's answer to
// one call with a stand-in desk, the program's side of one call, and the whole way on a socket of the test's own.
// The app's own desk (`LinkTools.grantDesk`) and the function that signs (`GrantSigning.send`) are in the app
// target, which has no tests. No test reads a Keychain, signs anything, reaches a hub or sleeps for a fixed time: a
// test waits with a bound of looks.

/// What the tests of `grant_secret` share: an example fleet, example calls, and the tool's sentences in two lists.
enum GrantSecretSample {
    static let fleet = "0f1e2d3c4b5a6978"
    /// An API key of the list, another API key of the same variable name, a login, and a reference of no secret.
    static let key = SaveSecretSample.reference
    static let twin = "bws://aaaaaaaa-bbbb-4ccc-8ddd-ffffffffffff"
    static let password = "bws://11111111-2222-4333-8444-555555555555"
    static let unknown = "bws://99999999-9999-4999-8999-999999999999"
    static let worker = "worker-1"

    /// The fleet's list: the three secrets, with the grants of the key and of its twin, and three agents.
    static func list(grants: [String: String] = [:], twin held: [String: String] = [:]) -> GrantSecret.Team {
        GrantSecret.Team(
            secrets: [key: .init(apiKey: true, env: "EXAMPLE_API_KEY", grants: grants),
                      twin: .init(apiKey: true, env: "EXAMPLE_API_KEY", grants: held),
                      password: .init(apiKey: false)],
            agents: [worker: .init(role: "worker", machine: "web-1"), "lead-1": .init(role: "lead", machine: "web-2"),
                     "manager": .init(role: "manager", machine: "hub")])
    }

    /// The same list with one agent alone: the worker, on the server of this name, or on none.
    static func list(workerOn machine: String?) -> GrantSecret.Team {
        GrantSecret.Team(secrets: list().secrets, agents: [worker: .init(role: "worker", machine: machine)])
    }

    static let give: [String: JSONValue] = ["login": .string(key), "agent": .string(worker), "level": .string("use")]
    static let read: [String: JSONValue] = ["login": .string(key), "agent": .string(worker), "level": .string("read")]
    static let takeBack: [String: JSONValue] = ["login": .string(key), "agent": .string(worker), "level": .null]

    static func with(_ more: [String: JSONValue]) -> [String: JSONValue] { give.merging(more) { $1 } }

    static func refusal(_ fields: [String: JSONValue]) -> String? {
        if case .failure(let refusal) = GrantSecret.read(fields) { return refusal.text }
        return nil
    }

    /// The checks before the writes, as the desk is asked for a call that passes them.
    static let checks = ["ready", "signs", "team", "vault", "key"]

    /// Each sentence of the tool for a refusal before its first write.
    static let before = [GrantSecret.only, GrantSecret.noPart, GrantSecret.loginWord, GrantSecret.agentWord,
                         GrantSecret.needsLevel, GrantSecret.levelWord, GrantSecret.notReady,
                         GrantSecret.noSignedGrants, GrantSecret.teamUnread, GrantSecret.vaultUnread,
                         GrantSecret.noFleet, GrantSecret.noVaultReading, GrantSecret.vaultSilent,
                         GrantSecret.noOwnerKey, GrantSecret.noOwnerKeyTakeBack, GrantSecret.noSecret,
                         GrantSecret.noAgent, GrantSecret.notWorker, GrantSecret.noServer, GrantSecret.readNeedsKey,
                         GrantSecret.readsTwice, GrantSecret.busy, GrantSecret.ended]
    /// Each sentence for a refusal after a write went out, and the program's words for a lost answer.
    static let after = [GrantSecret.signRefused, GrantSecret.signNotKnown, GrantSecret.grantRefusedTakenBack,
                        GrantSecret.grantRefusedSignatureLeft, GrantSecret.grantRefusedListHasOne,
                        GrantSecret.grantRefusedListUnread, GrantSecret.grantNotKnown, GrantSecret.endRefused,
                        GrantSecret.endNotKnown, GrantSecret.ungrantFailed, GrantSecret.notKnownHere]
    static let notes = [GrantSecret.noteVaultOn, GrantSecret.noteNoVaultAccess, GrantSecret.noteReads,
                        GrantSecret.noteSame, GrantSecret.noteDelivery, GrantSecret.noteTakenBack,
                        GrantSecret.noteNoGrant]

    /// The failures of a write that are "not known": no answer, an answer that could not be read, a status of 500
    /// or more, and any other error.
    static let notKnown: [any Error] = [SaveBotToken.HubFailure.noAnswer, SaveBotToken.HubFailure.unreadable,
                                        SaveBotToken.HubFailure.refused(500, "internal error"),
                                        SaveBotToken.HubFailure.refused(503, "the central vault does not answer"),
                                        URLError(.timedOut), CancellationError()]
}

/// **The app's engine for `grant_secret` as stand-ins**: the fleet as the app reads it, the hub's answer to each
/// write, and a record of what the desk was asked, in its order.
@MainActor
final class StandInGrantDesk {
    struct Place: Hashable, Sendable {
        var hub = "https://hub.example.com"
        var database = "gen-1"
    }

    /// One awaited closure of the desk, as it went on after its wait: its name, and whether the task that it ran in
    /// was cancelled then.
    struct Step: Equatable, Sendable {
        let name: String
        let cancelled: Bool
    }

    // The fleet, as the app reads it.
    var ready = true
    /// Whether the hub lists `signed_grants`, or nil for a reading of the app that moved.
    var signs: Bool? = true
    /// What each read of the team gives, in the order of the reads: a list, or nil for a read that fails. The last
    /// one serves each later read too.
    var teams: [GrantSecret.Team?] = [GrantSecretSample.list()]
    /// The vault's page, or nil for a read that fails.
    var vault: GrantSecret.Vault? = GrantSecret.Vault(fleet: GrantSecretSample.fleet, central: .answers)
    var holdsKey = true
    /// What each signed statement and each grant of the hub gets, in the order of the sends: nil when it was taken.
    /// The last one serves each later send too.
    var signAnswers: [(any Error)?] = [nil]
    var grantAnswers: [(any Error)?] = [nil]
    var receipt = GrantSecret.Receipt(changed: true)

    // What the desk was asked.
    var asked: [String] = []
    var statements: [GrantSecret.Statement] = []
    var grants: [String] = []
    var places: [Place] = []
    var refreshes = 0
    /// Each awaited closure, in its order, with whether its task was cancelled when it went on.
    var steps: [Step] = []
    /// The closure whose call cancels the task that called it, as the end of the call's connection does.
    var cancelAt: String?
    /// The closures that stop until the test opens them, and the calls that stand there now.
    var holdAt: Set<String> = []
    private var held: [(name: String, go: CheckedContinuation<Void, Never>)] = []

    let line = GrantSecret.Line()

    /// The writes that the desk was asked for: the signed statements and the hub's grants.
    var writes: Int { statements.count + grants.count }

    /// The signed statements with no machine: the `ungrant` ones.
    var ungrants: Int { statements.filter { $0.machine == nil }.count }

    func holds(_ name: String) -> Int { held.filter { $0.name == name }.count }

    func open(_ name: String) {
        guard let place = held.firstIndex(where: { $0.name == name }) else { return }
        held.remove(at: place).go.resume()
    }

    private func step(_ name: String) async {
        if holdAt.contains(name) { await withCheckedContinuation { held.append((name, $0)) } }
        if cancelAt == name { withUnsafeCurrentTask { $0?.cancel() } }
        steps.append(Step(name: name, cancelled: Task.isCancelled))
    }

    /// The next answer of a list, which keeps its last one for each later ask.
    private func next<Answer>(_ answers: inout [Answer]) -> Answer? {
        guard let first = answers.first else { return nil }
        if answers.count > 1 { answers.removeFirst() }
        return first
    }

    var desk: GrantSecret.Desk<Place> {
        GrantSecret.Desk<Place>(
            ready: { [self] in
                asked.append("ready")
                return ready ? Place() : nil
            },
            signs: { [self] _ in
                asked.append("signs")
                return signs
            },
            team: { [self] place in
                asked.append("team")
                places.append(place)
                await step("team")
                guard let found = next(&teams), let list = found else { throw SaveBotToken.HubFailure.noAnswer }
                return list
            },
            vault: { [self] place in
                asked.append("vault")
                places.append(place)
                await step("vault")
                guard let vault else { throw SaveBotToken.HubFailure.noAnswer }
                return vault
            },
            holdsKey: { [self] fleet in
                asked.append("key")
                return fleet == GrantSecretSample.fleet && holdsKey
            },
            // The vault's own rule for a server's name, as the app's wiring asks it.
            isMachine: { CentralVault.isMachine($0) },
            sign: { [self] place, statement in
                asked.append(statement.machine.map { "sign grant \($0)" } ?? "sign ungrant")
                statements.append(statement)
                places.append(place)
                await step("sign")
                if let found = next(&signAnswers), let error = found { throw error }
            },
            grant: { [self] place, login, agent, level in
                asked.append("grant \(level?.rawValue ?? "null")")
                grants.append("\(login) \(agent) \(level?.rawValue ?? "null")")
                places.append(place)
                await step("grant")
                if let found = next(&grantAnswers), let error = found { throw error }
                return receipt
            },
            refresh: { [self] in
                asked.append("refresh")
                refreshes += 1
            })
    }

    func answer(_ fields: [String: JSONValue], value: OwnerChannel.Value? = nil) async -> OwnerChannel.Answer {
        await GrantSecret.answer(fields: fields, value: value, desk: desk, line: line)
    }

    /// The fields of a call's result, or nil for a refusal.
    func result(_ fields: [String: JSONValue]) async -> [String: JSONValue]? {
        if case .result(let value) = await answer(fields) { return value.object }
        return nil
    }

    /// A call that a test expects to go, which did not: the words of its refusal.
    struct Refused: Error, CustomStringConvertible {
        let description: String
    }

    /// The fields of the result of a call that must go: a refusal is the test's error.
    func went(_ fields: [String: JSONValue]) async throws -> [String: JSONValue] {
        switch await answer(fields) {
        case .result(let value): return value.object ?? [:]
        case .refused(let words): throw Refused(description: words)
        }
    }

    /// The words of a call's refusal, or nil for a result.
    func refusal(_ fields: [String: JSONValue]) async -> String? {
        if case .refused(let words) = await answer(fields) { return words }
        return nil
    }

    /// One call in a task of its own, so that a cancel of the call's task is no cancel of the test's.
    func call(_ fields: [String: JSONValue]) -> Task<OwnerChannel.Answer, Never> {
        Task { @MainActor in await self.answer(fields) }
    }
}

// ------------------------------------------------------------ the fields

/// **The fields of `grant_secret`**: `login`, `agent` and `level`, all three required, each in one strict form.
struct OwnerGrantSecretFieldTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let hub = root.appendingPathComponent("hub.py")

    let key = GrantSecretSample.key

    private func with(_ more: [String: JSONValue]) -> [String: JSONValue] { GrantSecretSample.with(more) }
    private func said(_ fields: [String: JSONValue]) -> String? { GrantSecretSample.refusal(fields) }

    /// A give at each level, and a take-back, which only a JSON null is.
    @Test func theThreeFieldsAreReadAsTheyCame() {
        #expect(GrantSecret.read(GrantSecretSample.give)
                == .success(GrantSecret.Read(login: key, agent: "worker-1", level: .use)))
        #expect(GrantSecret.read(GrantSecretSample.read)
                == .success(GrantSecret.Read(login: key, agent: "worker-1", level: .read)))
        #expect(GrantSecret.read(GrantSecretSample.takeBack)
                == .success(GrantSecret.Read(login: key, agent: "worker-1", level: nil)))
        #expect(GrantSecret.fields == ["login", "agent", "level"])
        #expect(GrantSecret.Level.use.rawValue == SecretGrant.use.rawValue)
        #expect(GrantSecret.Level.read.rawValue == SecretGrant.read.rawValue)
    }

    /// **A missing `level` is refused**: a field that was forgotten never takes access back. A `level` of another
    /// kind, or another word, has its own sentence.
    @Test func aMissingLevelIsRefusedAndNeverATakeBack() {
        #expect(said(GrantSecretSample.give.filter { $0.key != "level" }) == GrantSecret.needsLevel)
        #expect(GrantSecret.needsLevel.contains("A call with no level takes nothing back."))
        let wrong: [JSONValue] = [.string("write"), .string("USE"), .string("Read"), .string(""), .string("null"),
                                  .string("none"), .string("use "), .string("use\n"), .int(1), .bool(false),
                                  .array([.string("use")]), .object([:])]
        for level in wrong { #expect(said(with(["level": level])) == GrantSecret.levelWord, "\(level)") }
    }

    /// A field that the tool does not take, and a field named like a value, whatever each holds.
    @Test func anUnknownFieldAndAFieldNamedLikeAValueAreRefused() {
        for name in ["request_id", "resource", "Level", "grant", "machine", "server", "from", "path", ""] {
            #expect(said(with([name: .string("x")])) == GrantSecret.only, "\(name)")
            #expect(said(with([name: .null])) == GrantSecret.only, "\(name)")
        }
        for name in ["value", "secret", "token", "api_key", "password", "Secret_Level", "login_key"] {
            #expect(said(with([name: .string("x")])) == OwnerLinkTools.neverAField, "\(name)")
            #expect(said(with([name: .null])) == OwnerLinkTools.neverAField, "\(name)")
        }
        // A field named like a value comes first, then an unknown field, then the forms.
        #expect(said(["token": .string("x"), "more": .int(1)]) == OwnerLinkTools.neverAField)
        #expect(said(["more": .int(1)]) == GrantSecret.only)
        // No field of the tool is named like a value, and the sentence for an unknown field names each one.
        for name in GrantSecret.fields {
            #expect(!OwnerLinkTools.namedLikeAValue(name), "\(name)")
            #expect(GrantSecret.only.contains(name), "\(name)")
        }
    }

    /// **The reference is the list's own spelling**: `bws://` and a UUID in lower case. `secret:` before it, capital
    /// letters and anything after it are refused, and the tool's form is the app's own (`LoginSecret.isReference`).
    @Test func theReferenceHasTheListsOwnSpelling() {
        let rest = String(key.dropFirst(6))
        let good: [String] = [key, GrantSecretSample.twin, "bws://00000000-0000-0000-0000-000000000000"]
        let bad: [String] = ["", "bws://", "secret:" + key, key.uppercased(), "BWS://" + rest,
                             "bws://AAAAAAAA-bbbb-4ccc-8ddd-eeeeeeeeeeee", key + "\n", key + " ", " " + key,
                             key + "0", String(key.dropLast()), rest, "bws:/" + rest,
                             "bws://aaaaaaaa_bbbb_4ccc_8ddd_eeeeeeeeeeee", "bws://aaaaaaaabbbb4ccc8dddeeeeeeeeeeee",
                             "bws://gggggggg-bbbb-4ccc-8ddd-eeeeeeeeeeee", "EXAMPLE_API_KEY",
                             "shop.example.com · owner"]
        for text in good {
            #expect(GrantSecret.isReference(text) && LoginSecret.isReference(text), "\(text)")
            #expect(said(with(["login": .string(text)])) == nil, "\(text)")
        }
        for text in bad {
            #expect(!GrantSecret.isReference(text), "\(text.debugDescription)")
            #expect(said(with(["login": .string(text)])) == GrantSecret.loginWord, "\(text.debugDescription)")
            // The app's own form is a search, which also takes a text with a line end after it; the tool's is a
            // whole match. For each other text the two agree.
            if !text.hasSuffix("\n") { #expect(!LoginSecret.isReference(text), "\(text.debugDescription)") }
        }
        let others: [JSONValue] = [.null, .int(7), .bool(true), .array([.string(key)])]
        for other in others { #expect(said(with(["login": other])) == GrantSecret.loginWord, "\(other)") }
        #expect(said(GrantSecretSample.give.filter { $0.key != "login" }) == GrantSecret.loginWord)
        #expect(GrantSecret.loginWord.contains("in lower case, with no secret: before it"))
    }

    /// **An agent's name by the hub's own rule**: 2 to 31 characters of a-z, 0-9 and "-", with a letter first.
    @Test func theAgentsNameHasTheHubsForm() throws {
        let good: [String] = ["worker-1", "nova", "ab", "a1", "a-", "a" + String(repeating: "b", count: 30), "door",
                              "owner"]
        let bad: [String] = ["", "a", "Worker-1", "1worker", "-worker", "worker_1", "worker 1", "worker-1 ",
                             " worker-1", "worker-1\n", "w\u{F6}rker", "a" + String(repeating: "b", count: 31),
                             "worker.1", "worker/1"]
        let rule = try NSRegularExpression(pattern: "^[a-z][a-z0-9-]{1,30}\\z")
        for name in good + bad {
            let whole = rule.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
            #expect(GrantSecret.isAgentName(name) == whole, "\(name.debugDescription)")
            #expect(whole == good.contains(name), "\(name.debugDescription)")
        }
        for name in bad {
            #expect(said(with(["agent": .string(name)])) == GrantSecret.agentWord, "\(name.debugDescription)")
        }
        let others: [JSONValue] = [.null, .int(7), .array([.string("worker-1")])]
        for other in others { #expect(said(with(["agent": other])) == GrantSecret.agentWord, "\(other)") }
        #expect(said(GrantSecretSample.give.filter { $0.key != "agent" }) == GrantSecret.agentWord)
    }

    /// **The checks run in their order**: of two faults in one call, the earlier check's sentence is the answer.
    @Test func theChecksOfTheFieldsRunInTheirOrder() {
        #expect(said([:]) == GrantSecret.loginWord)
        #expect(said(["login": .string("x"), "agent": .string("X"), "level": .string("x")]) == GrantSecret.loginWord)
        #expect(said(["login": .string(key), "agent": .string("X"), "level": .string("x")]) == GrantSecret.agentWord)
        #expect(said(["login": .string(key), "agent": .string("worker-1"), "level": .string("x")])
                == GrantSecret.levelWord)
        #expect(said(["login": .string(key), "agent": .string("worker-1")]) == GrantSecret.needsLevel)
        #expect(said(["login": .string("x"), "more": .int(1)]) == GrantSecret.only)
    }

    /// **The program's plan is the three fields as they came**, with `level` as a JSON null for a take-back, and
    /// the app's read takes what the plan sends.
    @Test func thePlanSendsTheThreeFieldsAndANullForATakeBack() throws {
        for fields in [GrantSecretSample.give, GrantSecretSample.read, GrantSecretSample.takeBack] {
            let send = try GrantSecret.plan(fields).get()
            #expect(send == fields && send.count == 3)
            #expect(GrantSecret.read(send) == GrantSecret.read(fields))
        }
        let back = try GrantSecret.plan(GrantSecretSample.takeBack).get()
        #expect(back["level"] == JSONValue.null)
        guard case .failure(let refusal) = GrantSecret.plan(GrantSecretSample.give.filter { $0.key != "level" }) else {
            Issue.record("a plan with no level")
            return
        }
        #expect(refusal.text == GrantSecret.needsLevel)
    }

    /// **No refusal of the fields quotes what the caller sent**: the marker as each field's text, as a field's
    /// name and inside a value of another kind.
    @Test func theRefusalsOfTheFieldsQuoteNothing() {
        var cases: [[String: JSONValue]] = []
        for base in [GrantSecretSample.give, GrantSecretSample.takeBack, [:]] {
            for field in GrantSecret.fields + [marker, marker + "_secret", "token"] {
                cases.append(base.merging([field: .string(marker)]) { $1 })
                cases.append(base.merging([field: .array([.string(marker)])]) { $1 })
                cases.append(base.merging([field: .object([marker: .string(marker)])]) { $1 })
            }
            cases.append(base.merging(["login": .string("bws://" + marker)]) { $1 })
            cases.append(base.merging(["login": .string("secret:" + key), "agent": .string(marker)]) { $1 })
        }
        var refusals = 0
        for fields in cases {
            guard let text = said(fields) else { continue }
            refusals += 1
            #expect(!text.lowercased().contains(marker) && !text.contains("zq"), "\(text)")
            #expect(text.hasSuffix(" Nothing was sent."), "\(text)")
        }
        // A text with the form of an agent's name passes the read: the app then looks for it in the team.
        #expect(said(with(["agent": .string(marker)])) == nil && refusals > 40)
    }

    /// **The forms and the door's name are the hub's own**, where this repository has the hub's file (the public
    /// copy of the apps has no root Python file): the pattern of an agent's name, the name that the hub reads as
    /// the door's own grant, the levels, the roles that hold a secret of the central vault, and the rule of two
    /// keys of one name.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: OwnerGrantSecretFieldTests.hub.path)))
    func theFormsAndTheDoorsNameAreTheHubsOwn() throws {
        let source = try String(contentsOf: Self.hub, encoding: .utf8)
        #expect(source.contains(#"AGENT_NAME = re.compile(r"^[a-z][a-z0-9-]{1,30}\Z")"#))
        #expect(source.contains("    if agent == \"\(GrantSecret.door)\":"))
        #expect(source.contains(#"if "grant" not in data or data["grant"] not in ("use", "read", None):"#))
        #expect(source.contains(#"if a.get("role") not in ("worker", "lead")"#))
        #expect(source.contains("def read_twice(team, agent, ref):"))
        #expect(GrantSecret.holderRoles == ["worker", "lead"])
    }

    /// The door's name is the app's own (`DoorAccess.holder`), and it has the form of an agent's name: only the
    /// tool's own check keeps it out.
    @Test func theDoorsNameIsTheAppsOwn() {
        #expect(GrantSecret.door == DoorAccess.holder)
        #expect(GrantSecret.isAgentName(GrantSecret.door))
    }
}

// ------------------------------------------------------------ the words

/// **The words of `grant_secret`**: the tool as the program lists it, its description, and its fixed sentences.
struct OwnerGrantSecretWordsTests {
    /// **The tool is a write with three required fields and no value, and it is listed**: the fourth of
    /// `OwnerLinkTools.names` and `tools`, one time in each, and no tool of `owner_mcp.py`'s table. (It was the last
    /// one until `share_secret` came after it.)
    @Test func theToolIsAWriteWithThreeRequiredFieldsAndIsListed() throws {
        let tool = GrantSecret.tool
        #expect(tool.name == "grant_secret" && GrantSecret.name == "grant_secret" && tool.what == "grant_secret")
        #expect(tool.annotations == .object(["readOnlyHint": .bool(false)]))
        #expect(OwnerTools.verb(of: tool) == .write)
        #expect(tool.inputSchema["required"] == .array([.string("login"), .string("agent"), .string("level")]))
        #expect(tool.inputSchema["additionalProperties"] == .bool(false))
        let properties = try #require(tool.inputSchema["properties"]?.object)
        #expect(Set(properties.keys) == Set(GrantSecret.fields) && properties.count == 3)
        #expect(properties["login"] == .object(["type": .string("string")]))
        #expect(properties["agent"] == .object(["type": .string("string")]))
        #expect(properties["level"] == .object(["type": .array([.string("string"), .string("null")]),
                                                "enum": .array([.string("use"), .string("read"), .null])]))
        #expect(tool.feature == nil && tool.route.isEmpty && !tool.requestIDFromArguments && tool.fields.isEmpty)
        #expect(tool.firstSentence == "Gives one secret of the fleet to one agent with the owner's signature, or "
                + "takes it back, as Give and Take back on the Founderizer app's Secrets page do.")
        #expect(OwnerLinkTools.names == ["save_bot_token", "prepare_problem_report", "save_secret", "grant_secret",
                                         "share_secret"])
        #expect(OwnerLinkTools.names.firstIndex(of: GrantSecret.name) == 3 && OwnerLinkTools.names.count == 5)
        #expect(OwnerLinkTools.names.filter { $0 == GrantSecret.name }.count == 1)
        #expect(OwnerLinkTools.tools.map(\.name) == OwnerLinkTools.names)
        #expect(OwnerLinkTools.tools[3].description == tool.description)
        // Not a tool of owner_mcp.py's table: a tool of the program only. The program lists it last but one, before
        // `share_secret`.
        #expect(Fixture.table.tool(GrantSecret.name) == nil)
        let listed = OwnerTools.programTable(Fixture.table).tools.filter { $0.kind.listed }
        #expect(listed.suffix(2).map(\.name) == [GrantSecret.name, ShareSecret.name])
        #expect(listed.filter { $0.name == GrantSecret.name }.count == 1)
        // It has its own words for a lost answer.
        #expect(OwnerLinkTools.notKnownHere(GrantSecret.name) == GrantSecret.notKnownHere)
        #expect(GrantSecret.notKnownHere != OwnerLinkTools.notKnownOther)
    }

    /// **What the description says**, sentence for sentence, and what it must not: no word of it says that an agent
    /// can read a login.
    @Test func theDescriptionSaysWhatItMust() {
        let words = GrantSecret.tool.description
        let sentences: [String] = [
            "Gives one secret of the fleet to one agent with the owner's signature, or takes it back, as Give and "
                + "Take back on the Founderizer app's Secrets page do.",
            "On a fleet with a central vault, the vault sends a secret's value to a server only for a grant that "
                + "the owner's key signed.",
            "This tool makes the Founderizer app sign the grant with the owner's key on this Mac and send it, and "
                + "then the hub writes the grant into the fleet's list.",
            "login: the secret's reference as fleet_read(page=\"team\") gives it under logins: bws:// and a UUID in "
                + "lower case, with no secret: before it.",
            "agent: the agent's name as that page gives it; for a give, it must be a worker or a lead.",
            "level: use, read or null, and it must be given.",
            "use lets the agent use the secret and never see it.",
            "read is only for an API key: it puts the key's value into that agent's sessions as a variable, so "
                + "give read only when the owner asked for it.",
            "null takes the secret back: the hub ends the grant in the list, and the app ends the owner's signature "
                + "of it.",
            "A give signs first and writes the list second.",
            "When the hub refuses the grant, the app reads the list again and takes its signature back when the list "
                + "has no grant of this secret for this agent.",
            "Only the Mac that set up Founderizer Vault holds the owner's key and can sign.",
            "On a hub that takes no signed grant, the tool sends nothing: grant_access gives a secret there.",
            "While the hub has no reading of a central vault, the tool sends nothing too: the fleet has none, or the "
                + "hub has not read it since it started, and only on a fleet that has none does grant_access give a "
                + "secret in this tool's place.",
            "A grant that grant_access wrote into the list with no signature is repaired by the same give at the "
                + "same level, which signs it.",
            "It answers login, agent, level, signed true, server (the server that a give was signed for), changed "
                + "(whether the hub changed its list), vault (the agent's vault access before and after, with the "
                + "hub's codes for what is missing, when the hub says it) and note.",
            "After a give, when the central vault holds the value and that server's vault takes deliveries, the "
                + "central vault sends it at the hub's next pass, usually within a minute (a delivery that failed "
                + "waits up to six hours before the next try); fleet_read(page=\"vault\") then lists the secret under "
                + "held for that server.",
            "One call writes at a time: a call that comes while another one is at its writes is refused.",
            "No answer has a secret's value.",
        ]
        for sentence in sentences { #expect(words.contains(sentence), "\(sentence)") }
        // The description is these sentences, in this order, and nothing more.
        #expect(words == sentences.joined(separator: " "))
        for word in ["read a login", "reads a login", "read the login", "reads the login", "read the secret",
                     "reads the secret", "see the secret"] {
            #expect(!words.contains(word), "\(word)")
        }
        // It names no other tool of the link.
        for other in OwnerLinkTools.names where other != GrantSecret.name {
            #expect(!words.contains(other), "\(other)")
        }
        #expect(!words.contains("\n") && !words.contains("  "))
    }

    /// **Each fixed sentence, word for word.** An agent acts on these words: what was sent, what was signed, and
    /// what it does next. A change of one of them is a decision, and this test is where it shows.
    @Test func eachSentenceBeforeAWriteIsHeldWordForWord() {
        #expect(GrantSecret.only == "grant_secret takes only login, agent and level. Nothing was sent.")
        #expect(GrantSecret.noPart == "grant_secret takes no part after its request line. Nothing was sent.")
        #expect(GrantSecret.loginWord == "login must be the secret's reference as fleet_read(page=\"team\") gives it "
                + "under logins: bws:// and a UUID in lower case, with no secret: before it. Nothing was sent.")
        #expect(GrantSecret.agentWord == "agent must be the agent's name as fleet_read(page=\"team\") gives it: 2 to "
                + "31 characters of a-z, 0-9 and -, with a letter first. Nothing was sent.")
        #expect(GrantSecret.needsLevel == "grant_secret needs level: use, read, or null to take the secret back. A "
                + "call with no level takes nothing back. Nothing was sent.")
        #expect(GrantSecret.levelWord == "level must be use, read or null. use lets the agent use the secret and "
                + "never see it, read is only for an API key, and null takes the secret back. Nothing was sent.")
        #expect(GrantSecret.notReady == "The Founderizer app's reading of the fleet is not current now, or the app "
                + "has no fleet. Call grant_secret again in a moment. Nothing was sent.")
        #expect(GrantSecret.noSignedGrants == "This hub takes no signed grant, so the app signs nothing for it: "
                + "grant_access gives a secret on such a fleet. Nothing was sent.")
        #expect(GrantSecret.teamUnread == "The Founderizer app could not read the fleet's list from the hub. Call "
                + "grant_secret again in a moment. Nothing was sent.")
        #expect(GrantSecret.vaultUnread == "The Founderizer app could not read the central vault's status from the "
                + "hub. Call grant_secret again in a moment. Nothing was sent.")
        #expect(GrantSecret.noFleet == "The hub did not say which fleet this is, so the app cannot sign for it. Call "
                + "grant_secret again in a moment. Nothing was sent.")
        #expect(GrantSecret.noVaultReading == "The hub has no reading of a central vault now: this fleet has none, "
                + "or the hub has not read it since it started. Call grant_secret again in a minute. If the same "
                + "answer comes again, ask the owner whether this fleet has Founderizer Vault: only on a fleet that "
                + "has none does grant_access give a secret in this tool's place. Nothing was sent.")
        #expect(GrantSecret.vaultSilent == "The hub's last reading of the central vault failed, so the vault may not "
                + "answer now. Call grant_secret again in a minute. Nothing was sent.")
        #expect(GrantSecret.noOwnerKey == "This Mac holds no owner key for this fleet, so the app on it cannot sign: "
                + "only the Mac that set up Founderizer Vault signs. Nothing was sent.")
        #expect(GrantSecret.noOwnerKeyTakeBack == "This Mac holds no owner key for this fleet, so the app on it "
                + "cannot sign: only the Mac that set up Founderizer Vault signs. grant_access with level null ends "
                + "the grant in the fleet's list, and the owner's signed grant then stays in the vault until that "
                + "Mac ends it. Nothing was sent.")
        #expect(GrantSecret.noSecret == "The fleet's list has no secret of that reference: fleet_read(page=\"team\") "
                + "gives the references under logins. Nothing was sent.")
        #expect(GrantSecret.noAgent == "The fleet has no agent of that name: fleet_read(page=\"team\") gives the "
                + "agents. Nothing was sent.")
        #expect(GrantSecret.notWorker == "That agent is no worker and no lead, and the hub delivers a secret of the "
                + "central vault only for a worker or a lead. Nothing was sent.")
        #expect(GrantSecret.noServer == "The hub names no server for that agent, so there is no server to sign the "
                + "grant for. Nothing was sent.")
        #expect(GrantSecret.readNeedsKey == "level read is only for an API key, and that secret is no API key: a "
                + "login is used and never seen. Give it with level use. Nothing was sent.")
        #expect(GrantSecret.readsTwice == "That agent already reads another API key of the same variable name, and "
                + "a session has one value for one name. Ask the owner which of the two keys that agent reads. "
                + "Nothing was sent.")
        #expect(GrantSecret.busy == "Another call of grant_secret is at its writes now. Call again when it has "
                + "answered. Nothing was sent.")
        #expect(GrantSecret.ended == "The call ended before its first write. Nothing was sent.")
        // At the first write of a give, when this Mac held the key a moment ago and the app could not sign with it.
        #expect(GrantSecret.notSignedNow == "This Mac held an owner key for this fleet a moment ago, and the app "
                + "could not sign with it now: the Mac can be locked, the key can be gone, or macOS did not let the "
                + "app read it. Nothing was sent. Call grant_secret again later.")
    }

    /// The sentences after a write went out, the program's words for a lost answer, and the notes, word for word.
    @Test func eachSentenceAfterAWriteAndEachNoteIsHeldWordForWord() {
        #expect(GrantSecret.signRefused == "The hub refused the owner's signed grant, so nothing was changed.")
        #expect(GrantSecret.signNotKnown == "Whether the vault took the owner's signed grant is not known, and the "
                + "fleet's list was not changed. Call grant_secret again in the same way: a second signature of the "
                + "same grant is no error, because the vault keeps the newer one.")
        #expect(GrantSecret.grantRefusedTakenBack == "The hub refused the grant, and the app took the owner's "
                + "signature of it back: the fleet's list has no grant of this secret for this agent, and the vault no "
                + "signed grant of it for this agent.")
        #expect(GrantSecret.grantRefusedSignatureLeft == "The hub refused the grant, and the app could not take the "
                + "owner's signature of it back: a signed grant of this secret for this agent stays in the vault "
                + "with no grant in the fleet's list. Call grant_secret with level null to end it.")
        #expect(GrantSecret.grantRefusedListHasOne == "The hub refused this call. The fleet's list has a grant of "
                + "this secret for this agent, which stays as it is, and the owner's signature stands for it.")
        #expect(GrantSecret.grantRefusedListUnread == "The hub refused the grant. The app signed the grant before "
                + "that and could not read the fleet's list after it. Read fleet_read(page=\"team\"). If the list has "
                + "no grant of this secret for this agent, call grant_secret with level null to end the signed "
                + "grant. If it has one, change nothing: the signature stands for it.")
        #expect(GrantSecret.grantNotKnown == "The app signed the grant with the owner's key, and whether the "
                + "fleet's list has the grant is not known. Call grant_secret again in the same way, or read "
                + "fleet_read(page=\"team\").")
        #expect(GrantSecret.endRefused == "The hub refused the end of the grant, so nothing was changed.")
        #expect(GrantSecret.endNotKnown == "Whether the hub ended the grant in the fleet's list is not known, and "
                + "the owner's signed grant is not ended. Call grant_secret again in the same way.")
        #expect(GrantSecret.ungrantFailed == "The grant is ended in the fleet's list, so the agent's access is "
                + "ended. The owner's signed grant stays in the vault. Call grant_secret with level null again to "
                + "end it: the hub's end is then no change, and the end of the signature is sent again.")
        #expect(GrantSecret.notKnownHere == "The Founderizer app did not answer in time, or the link ended, so what "
                + "the app signed and wrote for this call is not known. Call grant_secret again in the same way: "
                + "that is safe for a give and for a take-back. fleet_read with the pages team and vault shows the "
                + "grant in the fleet's list and the owner's signed grants.")
        #expect(GrantSecret.noteVaultOn == "The agent uses its server's vault now.")
        #expect(GrantSecret.noteNoVaultAccess == "The agent has the secret and no vault access yet, so it cannot "
                + "use it now: vault.missing has the hub's codes for what is missing.")
        #expect(GrantSecret.noteReads == "The agent reads the key as a variable in its sessions from their next "
                + "start.")
        #expect(GrantSecret.noteSame == "The fleet's list had this grant at this level already, so the hub changed "
                + "nothing in it, and the owner's signature of it is in the vault now.")
        #expect(GrantSecret.noteDelivery == "When the central vault holds the value and that server's vault takes "
                + "deliveries, the central vault sends it at the hub's next pass, usually within a minute (a delivery "
                + "that failed waits up to six hours before the next try); fleet_read(page=\"vault\") then lists the "
                + "secret under held for that server.")
        #expect(GrantSecret.noteTakenBack == "The hub ended the grant in the fleet's list, and the app ended the "
                + "owner's signed grant in the vault.")
        #expect(GrantSecret.noteNoGrant == "The fleet's list had no grant of this secret for this agent, so the hub "
                + "changed nothing in it, and the app sent the end of the owner's signed grant to the vault.")
    }

    /// **"Nothing was sent." exactly when nothing was sent**: each refusal before the first write ends with those
    /// words, and no sentence after a write has them. No sentence says that the app signed for a call that signed
    /// nothing, none says that an agent can read a login, and none names another tool of the link.
    @Test func theSentencesSayNothingWasSentExactlyWhenNothingWas() {
        let before = GrantSecretSample.before, after = GrantSecretSample.after, notes = GrantSecretSample.notes
        #expect(Set(before + after + notes).count == before.count + after.count + notes.count)
        for words in before + [OwnerLinkTools.neverAField] {
            #expect(words.hasSuffix(" Nothing was sent."), "\(words)")
            #expect(words.components(separatedBy: "Nothing was sent").count == 2, "\(words)")
            for claim in ["app signed", "signed true", "signed the grant", "took the owner's", "is ended in"] {
                #expect(!words.contains(claim), "\(words)")
            }
        }
        for words in after + notes {
            #expect(!words.contains("Nothing was sent") && !words.contains("nothing was sent"), "\(words)")
        }
        // The one sentence of the first write of a give that the app could not sign: nothing was sent, and its last
        // words are the next step. It does not say that this Mac holds no key, because the check said that it held
        // one a moment ago.
        let notSigned = GrantSecret.notSignedNow
        #expect(notSigned.components(separatedBy: "Nothing was sent.").count == 2)
        #expect(notSigned.hasSuffix(" Nothing was sent. Call grant_secret again later."))
        #expect(notSigned.hasPrefix("This Mac held an owner key") && !notSigned.contains("holds no owner key"))
        #expect(!before.contains(notSigned) && !after.contains(notSigned))
        for claim in ["app signed", "signed true", "signed the grant", "not known"] {
            #expect(!notSigned.contains(claim), "\(claim)")
        }
        let hubSaid = GrantSecret.withHubWords(GrantSecret.signRefused, status: 400, "the statement is older")
        let others = OwnerLinkTools.names.filter { $0 != GrantSecret.name }
        #expect(others.count == 4)
        for words in before + after + notes + [hubSaid, notSigned] {
            for other in others { #expect(!words.contains(other), "\(words)") }
            for never in ["read a login", "reads a login", "read the login", "reads the login", "read the secret",
                          "reads the secret"] {
                #expect(!words.contains(never), "\(words)")
            }
            #expect(!words.contains("\n") && !words.contains("  "), "\(words)")
        }
        // A hub that takes no signed grant: the sentence names the tool that gives a secret there.
        #expect(GrantSecret.noSignedGrants.contains("grant_access"))
        // A page with no reading of a central vault is not "this fleet has no central vault": the sentence asks
        // for the same call again, then for the owner's word, and names `grant_access` only for a fleet with none.
        #expect(GrantSecret.noVaultReading.contains("or the hub has not read it since it started"))
        #expect(GrantSecret.noVaultReading.contains("Call grant_secret again in a minute."))
        #expect(GrantSecret.noVaultReading.contains("only on a fleet that has none does grant_access give a secret"))
        #expect(!GrantSecret.noVaultReading.contains("This fleet has no central vault"))
        #expect(!GrantSecret.vaultSilent.contains("grant_access"))
        // No sentence tells the caller to take access away, or to end a grant, with no look at the list first.
        #expect(!GrantSecret.readsTwice.contains("Take the other key back"))
        #expect(GrantSecret.readsTwice.contains("Ask the owner which of the two keys that agent reads."))
        #expect(!GrantSecret.grantRefusedListUnread.contains("end both"))
        #expect(GrantSecret.grantRefusedListUnread.contains("If it has one, change nothing"))
        // The take-back's sentence for a Mac with no owner key is the give's, with what that Mac can still do.
        let common = GrantSecret.noOwnerKey.replacingOccurrences(of: " Nothing was sent.", with: "")
        #expect(GrantSecret.noOwnerKeyTakeBack.hasPrefix(common) && GrantSecret.noOwnerKeyTakeBack != GrantSecret.noOwnerKey)
        #expect(GrantSecret.notKnownHere.contains("not known"))
        #expect(GrantSecret.notKnownHere.contains("safe for a give and for a take-back"))
    }

    /// **The hub's own words come after the tool's sentence, and only when they are plain**: a text of 1 to 300
    /// Unicode scalars with no control and no format character. Else fixed words say the status alone. The bound
    /// counts scalars and never characters: one letter with 100,000 combining marks is one character.
    @Test func theHubsWordsComeAfterTheToolsSentenceWhenTheyArePlain() {
        let sentence = GrantSecret.endRefused
        let hubs = "This agent already reads another key named EXAMPLE_API_KEY. A session has one value for one name."
        #expect(GrantSecret.withHubWords(sentence, status: 409, hubs)
                == "The hub refused the end of the grant, so nothing was changed. The hub's words (status 409): " + hubs)
        #expect(GrantSecret.withHubWords(sentence, status: 404, "no such secret")
                == sentence + " The hub's words (status 404): no such secret")
        let most = String(repeating: "w", count: GrantSecret.hubWordsMost)
        #expect(GrantSecret.hubWordsMost == 300)
        #expect(GrantSecret.withHubWords(sentence, status: 400, most).hasSuffix("(status 400): " + most))
        let fixed = sentence + " The hub answered with status 400, and with no words that pass."
        let hidden: [String] = ["", most + "w", "two\nlines", "a tab\there", "a bell\u{7}", "a mark\u{200B}here",
                                "a line\u{2028}separator", "\u{FEFF}start", "return\r"]
        for said in hidden {
            #expect(GrantSecret.withHubWords(sentence, status: 400, said) == fixed, "\(said.debugDescription)")
        }
        // Words of another script pass: the hub's words are data, and they stand last.
        #expect(GrantSecret.withHubWords(sentence, status: 400, "caf\u{E9} \u{4F8B}").hasSuffix(": caf\u{E9} \u{4F8B}"))
        // One letter with 100,000 combining marks after it: one character, and far more scalars than the bound.
        let stacked = "e" + String(repeating: "\u{301}", count: 100_000)
        #expect(stacked.count == 1 && stacked.unicodeScalars.count == 100_001)
        #expect(GrantSecret.withHubWords(sentence, status: 400, stacked) == fixed)
        #expect(!GrantSecret.withHubWords(sentence, status: 400, "refused " + stacked).contains("\u{301}"))
        // The bound itself, in scalars: 300 pass, and one more does not, however few characters they are.
        let atTheBound = "e" + String(repeating: "\u{301}", count: GrantSecret.hubWordsMost - 1)
        #expect(atTheBound.count == 1 && atTheBound.unicodeScalars.count == 300)
        #expect(GrantSecret.withHubWords(sentence, status: 400, atTheBound).hasSuffix("(status 400): " + atTheBound))
        #expect(GrantSecret.withHubWords(sentence, status: 400, atTheBound + "\u{301}") == fixed)
    }

    /// **A code of the hub in an answer has one narrow form**, and a text of another form is left out.
    @Test func aCodeOfTheHubHasOneForm() {
        for code in ["none", "broker", "no_vault_store", "agent_without_key", "a", String(repeating: "a", count: 40)] {
            #expect(GrantSecret.code(code) == code, "\(code)")
        }
        let others: [String] = ["", "No vault", "broker ", "a-b", "Broker", "caf\u{E9}", "a\nb",
                                String(repeating: "a", count: 41), marker]
        for text in others { #expect(GrantSecret.code(text) == nil, "\(text.debugDescription)") }
    }
}

// ------------------------------------------------------------ the vault's state

/// **What the vault's page says of the central vault** (`GrantSecret.Vault.Central.of`, which the app's wiring asks
/// with the page's central part, that part's `ok` and the page's `error`): one test for each case. The pages are
/// read by the app's own type (`VaultReading` in FleetCore), in the three shapes that the hub gives
/// (`hub.py` `central_read`, `vault_view`).
struct OwnerGrantSecretVaultStateTests {
    /// The rule on one page of the hub, read as the app reads it and asked as `LinkTools.vaultFacts` asks it.
    private func state(central: [String: Any]?, error: String?) throws -> GrantSecret.Vault.Central {
        let page: [String: Any] = ["db": "gen-1", "fleet": GrantSecretSample.fleet,
                                   "central": (central as Any?) ?? NSNull(), "read_at": 1_761_300_100.5,
                                   "error": (error as Any?) ?? NSNull(), "machines": [Any](),
                                   "held": [String: Any]()]
        let reading = try JSONDecoder().decode(VaultReading.self, from: JSONSerialization.data(withJSONObject: page))
        #expect(reading.fleetID == GrantSecretSample.fleet)
        return GrantSecret.Vault.Central.of(central: reading.central.map(\.ok), error: reading.error)
    }

    /// The central vault's status as the hub keeps it after a good read.
    private static var status: [String: Any] {
        ["ok": true, "central": true, "fleet": GrantSecretSample.fleet, "owner_keys": 1, "pins": [String: Any](),
         "grants": [Any](), "pool": [Any](), "items": 2]
    }

    /// **No central part is no reading**, with an error or with none: a fleet with no central vault, and a fleet
    /// whose vault did not answer since the hub started, give the same page. It is never "silent" and never
    /// "answers".
    @Test func noCentralPartIsNoReading() throws {
        #expect(GrantSecret.Vault.Central.of(central: nil, error: nil) == .noReading)
        #expect(GrantSecret.Vault.Central.of(central: nil, error: "no central vault answers on this hub") == .noReading)
        let errors: [String?] = [nil, "no central vault answers on this hub",
                                 "the central vault did not answer in 10 seconds"]
        for error in errors {
            let read = try state(central: nil, error: error)
            #expect(read == .noReading, "\(error ?? "no error")")
        }
    }

    /// **A central part with an error is silent**: the hub keeps its last good reading, whose `ok` is true, and
    /// sets `error` when its newest read failed. A part whose `ok` is not true is silent too.
    @Test func aCentralPartWithAnErrorIsSilent() throws {
        #expect(GrantSecret.Vault.Central.of(central: true, error: "the central vault did not answer") == .silent)
        #expect(GrantSecret.Vault.Central.of(central: true, error: "") == .silent)
        #expect(GrantSecret.Vault.Central.of(central: false, error: nil) == .silent)
        #expect(GrantSecret.Vault.Central.of(central: false, error: "the central vault did not answer") == .silent)
        let failed = try state(central: Self.status, error: "the central vault did not answer in 10 seconds")
        #expect(failed == .silent)
        var notOK = Self.status
        notOK["ok"] = false
        let saysNo = try state(central: notOK, error: nil)
        #expect(saysNo == .silent)
        notOK["ok"] = nil
        let saysNothing = try state(central: notOK, error: nil)
        #expect(saysNothing == .silent)
    }

    /// **A central part that says ok, with no error, answers.**
    @Test func aCentralPartThatSaysOkWithNoErrorAnswers() throws {
        #expect(GrantSecret.Vault.Central.of(central: true, error: nil) == .answers)
        let read = try state(central: Self.status, error: nil)
        #expect(read == .answers)
    }

    /// The hub's own code for the three shapes, where this repository has the hub's file: a status is kept only
    /// after an ok answer, a failed read keeps it and sets the error, and the page gives both as they are.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: OwnerGrantSecretFieldTests.hub.path)))
    func theThreeShapesAreTheHubsOwn() throws {
        let source = try String(contentsOf: OwnerGrantSecretFieldTests.hub, encoding: .utf8)
        #expect(source.contains("CENTRAL.update(tried_at=t0, error=str(e))"))
        #expect(source.contains("CENTRAL.update(status=answer, read_at=t0, tried_at=t0, error=None)"))
        #expect(source.contains(#"return {"fleet": fleet_id(), "central": status, "read_at": read_at, "error": error,"#))
        #expect(source.contains(#"CENTRAL_START = {"status": None, "read_at": None, "tried_at": 0.0, "error": None,"#))
    }
}

// ------------------------------------------------------------ the app's answer

/// **The app's answer to one call of `grant_secret`**, with a stand-in desk: each step in its order, with the
/// desk's calls counted, so that "Nothing was sent." is held by a desk whose two writes were never called.
@MainActor
struct OwnerGrantSecretAppTests {
    let give = GrantSecretSample.give
    let read = GrantSecretSample.read
    let takeBack = GrantSecretSample.takeBack
    let checks = GrantSecretSample.checks
    let key = GrantSecretSample.key
    let worker = GrantSecretSample.worker
    let fleet = GrantSecretSample.fleet

    /// Waits for a fact of another task, by a count of looks.
    private func comes(_ done: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    private func fields(_ answer: OwnerChannel.Answer) -> [String: JSONValue]? {
        if case .result(let value) = answer { return value.object }
        return nil
    }

    // ------------------------------------------------------------ the two calls that go

    /// **A give at `use`**: the checks, then the signed `grant` for the agent's server, then the hub's grant, then
    /// the app's refresh. The answer has the fields of the tool, and nothing else.
    @Test func aGiveSignsFirstAndWritesTheListSecond() async throws {
        let app = StandInGrantDesk()
        app.receipt = .init(changed: true, access: .init(before: "none", after: "broker"))
        let answer = try await app.went(give)
        #expect(app.asked == checks + ["sign grant web-1", "grant use", "refresh"])
        #expect(app.statements == [GrantSecret.Statement(fleet: fleet, login: key, agent: worker, machine: "web-1")])
        #expect(app.grants == ["\(key) \(worker) use"])
        #expect(app.refreshes == 1 && !app.line.busy)
        #expect(Set(app.places) == [StandInGrantDesk.Place()])
        let expected: [String: JSONValue] = [
            "login": .string(key), "agent": .string(worker), "level": .string("use"), "signed": .bool(true),
            "server": .string("web-1"), "changed": .bool(true),
            "vault": .object(["before": .string("none"), "after": .string("broker")]),
            "note": .string(GrantSecret.noteVaultOn + " " + GrantSecret.noteDelivery),
        ]
        #expect(answer == expected)
        // A lead on its own server, with no word of the hub about its vault: the delivery alone.
        let second = StandInGrantDesk()
        let lead = try await second.went(GrantSecretSample.with(["agent": .string("lead-1")]))
        #expect(second.statements.map(\.machine) == ["web-2"])
        #expect(lead["server"] == JSONValue.string("web-2") && lead["vault"] == nil)
        #expect(lead["note"] == JSONValue.string(GrantSecret.noteDelivery))
        // A login at `use` goes too.
        let third = StandInGrantDesk()
        let login = try await third.went(GrantSecretSample.with(["login": .string(GrantSecretSample.password)]))
        #expect(login["signed"] == JSONValue.bool(true))
        #expect(third.grants == ["\(GrantSecretSample.password) \(worker) use"])
    }

    /// **A give at `read`** of an API key: the same writes, and the note that the key is in the agent's sessions
    /// from their next start.
    @Test func aGiveAtReadSaysThatTheKeyIsInTheSessions() async throws {
        let app = StandInGrantDesk()
        let answer = try await app.went(read)
        #expect(app.asked == checks + ["sign grant web-1", "grant read", "refresh"])
        let expected: [String: JSONValue] = [
            "login": .string(key), "agent": .string(worker), "level": .string("read"), "signed": .bool(true),
            "server": .string("web-1"), "changed": .bool(true),
            "note": .string(GrantSecret.noteReads + " " + GrantSecret.noteDelivery),
        ]
        #expect(answer == expected)
        // The agent reads this key already: the same key again is no second key of that name.
        let again = StandInGrantDesk()
        again.teams = [GrantSecretSample.list(grants: [worker: "read"])]
        again.receipt = .init(changed: false)
        let same = try await again.went(read)
        #expect(same["changed"] == JSONValue.bool(false))
        // Another agent reads the twin, and this agent only uses it: that is no second key that this agent reads.
        let other = StandInGrantDesk()
        other.teams = [GrantSecretSample.list(twin: ["lead-1": "read", worker: "use"])]
        let went = try await other.went(read)
        #expect(went["signed"] == JSONValue.bool(true))
    }

    /// **A change that is no change** is the repair of a grant with no signature: the list had the grant at this
    /// level, the hub changed nothing, and the app signed it.
    @Test func aGiveThatChangesNothingStillSigns() async throws {
        let app = StandInGrantDesk()
        app.teams = [GrantSecretSample.list(grants: [worker: "use"])]
        app.receipt = .init(changed: false)
        let answer = try await app.went(give)
        #expect(app.asked == checks + ["sign grant web-1", "grant use", "refresh"])
        #expect(answer["changed"] == JSONValue.bool(false) && answer["signed"] == JSONValue.bool(true))
        #expect(answer["note"] == JSONValue.string(GrantSecret.noteSame + " " + GrantSecret.noteDelivery))
        // A `read` that changed nothing does not say "from their next start".
        let same = StandInGrantDesk()
        same.receipt = .init(changed: false)
        let unchanged = try await same.went(read)
        #expect(unchanged["note"] == JSONValue.string(GrantSecret.noteSame + " " + GrantSecret.noteDelivery))
    }

    /// **An agent with no vault access yet**: the answer has the hub's codes of what is missing, each in a code's
    /// form, and the note says that the agent cannot use the secret now.
    @Test func aGiveToAnAgentWithNoVaultAccessSaysSo() async throws {
        let app = StandInGrantDesk()
        app.receipt = .init(changed: true,
                            access: .init(before: "none", after: "none",
                                          missing: ["no_vault_store", "Not A Code " + marker, "broker_status_unknown"]))
        let answer = try await app.went(give)
        let vault: JSONValue = .object(["before": .string("none"), "after": .string("none"),
                                        "missing": .array([.string("no_vault_store"), .string("broker_status_unknown")])])
        #expect(answer["vault"] == vault)
        #expect(answer["note"] == JSONValue.string(GrantSecret.noteNoVaultAccess + " " + GrantSecret.noteDelivery))
        #expect(!JSONValue.object(answer).dumps().contains(marker))
        // A word of the hub that is no code is null, and never its text.
        let odd = StandInGrantDesk()
        odd.receipt = .init(changed: true, access: .init(before: "none", after: "broker " + marker))
        let other = try await odd.went(give)
        let nulled: JSONValue = .object(["before": .string("none"), "after": .null])
        #expect(other["vault"] == nulled)
        #expect(other["note"] == JSONValue.string(GrantSecret.noteNoVaultAccess + " " + GrantSecret.noteDelivery))
        #expect(!JSONValue.object(other).dumps().contains(marker))
    }

    /// **A take-back**: the checks, then the hub's end of the grant, then the signed `ungrant`. It makes none of
    /// the checks of a give: an end goes for a secret, an agent and a server that the list does not have.
    @Test func aTakeBackEndsTheListsGrantFirstAndTheSignatureSecond() async throws {
        let app = StandInGrantDesk()
        app.teams = [GrantSecretSample.list(grants: [worker: "read"])]
        let answer = try await app.went(takeBack)
        #expect(app.asked == checks + ["grant null", "sign ungrant", "refresh"])
        #expect(app.grants == ["\(key) \(worker) null"])
        #expect(app.statements == [GrantSecret.Statement(fleet: fleet, login: key, agent: worker, machine: nil)])
        let expected: [String: JSONValue] = [
            "login": .string(key), "agent": .string(worker), "level": .null, "signed": .bool(true),
            "changed": .bool(true), "note": .string(GrantSecret.noteTakenBack),
        ]
        #expect(answer == expected)
        // The list had no such grant: the hub changed nothing, and the end of the signature went.
        let none = StandInGrantDesk()
        none.receipt = .init(changed: false)
        let same = try await none.went(takeBack)
        #expect(same["changed"] == JSONValue.bool(false) && same["note"] == JSONValue.string(GrantSecret.noteNoGrant))
        #expect(same["server"] == nil && none.ungrants == 1 && none.statements.count == 1)
        // None of the checks of a give: a secret that the list does not have, an agent that the fleet does not
        // have, the fleet manager, a login, and an agent with no server.
        let ends: [[String: JSONValue]] = [
            GrantSecretSample.with(["login": .string(GrantSecretSample.unknown), "level": .null]),
            GrantSecretSample.with(["agent": .string("nobody"), "level": .null]),
            GrantSecretSample.with(["agent": .string("manager"), "level": .null]),
            GrantSecretSample.with(["login": .string(GrantSecretSample.password), "level": .null]),
            takeBack,
        ]
        for fields in ends {
            let other = StandInGrantDesk()
            other.teams = [GrantSecret.Team(secrets: [:], agents: [worker: .init(role: "worker", machine: nil)])]
            let went = await other.result(fields)
            #expect(went?["signed"] == JSONValue.bool(true), "\(fields)")
            #expect(other.asked == checks + ["grant null", "sign ungrant", "refresh"], "\(fields)")
        }
    }

    // ------------------------------------------------------------ each step, in its order

    /// One refusal before the first write: what the desk was asked up to it, and that neither write was called.
    private func refused(_ fields: [String: JSONValue], _ words: String, asked: [String],
                         value: OwnerChannel.Value? = nil, _ change: (StandInGrantDesk) -> Void = { _ in }) async {
        let app = StandInGrantDesk()
        change(app)
        let answer = await app.answer(fields, value: value)
        #expect(answer == .refused(words), "\(words)")
        #expect(app.asked == asked, "\(words)")
        #expect(app.writes == 0 && app.refreshes == 0 && !app.line.busy, "\(words)")
        #expect(words.hasSuffix(" Nothing was sent."), "\(words)")
    }

    /// **Step 1, the fields**: each refusal of the fields and a part after the request line, with the desk never
    /// asked.
    @Test func aWrongFieldAsksTheDeskNothing() async {
        await refused(give.filter { $0.key != "level" }, GrantSecret.needsLevel, asked: [])
        await refused(GrantSecretSample.with(["level": .string("write")]), GrantSecret.levelWord, asked: [])
        await refused(GrantSecretSample.with(["login": .string("secret:" + key)]), GrantSecret.loginWord, asked: [])
        await refused(GrantSecretSample.with(["login": .string(key.uppercased())]), GrantSecret.loginWord, asked: [])
        await refused(GrantSecretSample.with(["agent": .string("Worker 1")]), GrantSecret.agentWord, asked: [])
        await refused(GrantSecretSample.with(["more": .int(1)]), GrantSecret.only, asked: [])
        await refused(GrantSecretSample.with(["token": .string("x")]), OwnerLinkTools.neverAField, asked: [])
        await refused(give, GrantSecret.noPart, asked: [], value: OwnerChannel.Value(copying: Array("more".utf8)))
        await refused(takeBack, GrantSecret.noPart, asked: [], value: OwnerChannel.Value(copying: Array("more".utf8)))
    }

    /// **Steps 2 to 4, each with its own sentence, in their order.** Each case fails one check; the desk is asked
    /// up to that check, and no write is called.
    @Test func eachCheckRefusesInItsOrderAndSendsNothing() async {
        // 2. A current reading, with a hub that serves the Secrets page.
        await refused(give, GrantSecret.notReady, asked: ["ready"]) { $0.ready = false }
        // 3. Signed grants: a reading that moved is "not ready", and a hub that does not list them has its words.
        await refused(give, GrantSecret.notReady, asked: ["ready", "signs"]) { $0.signs = nil }
        await refused(give, GrantSecret.noSignedGrants, asked: ["ready", "signs"]) { $0.signs = false }
        await refused(takeBack, GrantSecret.noSignedGrants, asked: ["ready", "signs"]) { $0.signs = false }
        // 4. The two reads.
        await refused(give, GrantSecret.teamUnread, asked: ["ready", "signs", "team"]) { $0.teams = [nil] }
        await refused(takeBack, GrantSecret.teamUnread, asked: ["ready", "signs", "team"]) { $0.teams = [nil] }
        let reads = ["ready", "signs", "team", "vault"]
        await refused(give, GrantSecret.vaultUnread, asked: reads) { $0.vault = nil }
        await refused(give, GrantSecret.noFleet, asked: reads) { $0.vault = .init(fleet: nil, central: .answers) }
        await refused(give, GrantSecret.noVaultReading, asked: reads) {
            $0.vault = .init(fleet: GrantSecretSample.fleet, central: .noReading)
        }
        await refused(takeBack, GrantSecret.noVaultReading, asked: reads) {
            $0.vault = .init(fleet: GrantSecretSample.fleet, central: .noReading)
        }
        await refused(give, GrantSecret.vaultSilent, asked: reads) {
            $0.vault = .init(fleet: GrantSecretSample.fleet, central: .silent)
        }
        await refused(give, GrantSecret.noOwnerKey, asked: checks) { $0.holdsKey = false }
        await refused(takeBack, GrantSecret.noOwnerKeyTakeBack, asked: checks) { $0.holdsKey = false }
        // A key that this Mac holds for another fleet is no key for this one.
        await refused(give, GrantSecret.noOwnerKey, asked: checks) {
            $0.vault = .init(fleet: "ffffffffffffffff", central: .answers)
        }
        // For a give only.
        await refused(GrantSecretSample.with(["login": .string(GrantSecretSample.unknown)]), GrantSecret.noSecret,
                      asked: checks)
        await refused(GrantSecretSample.with(["agent": .string("nobody")]), GrantSecret.noAgent, asked: checks)
        await refused(GrantSecretSample.with(["agent": .string("manager")]), GrantSecret.notWorker, asked: checks)
        await refused(give, GrantSecret.noServer, asked: checks) { $0.teams = [GrantSecretSample.list(workerOn: nil)] }
        for name in ["", "Web-1", "web 1", "1web", String(repeating: "w", count: 64)] {
            await refused(give, GrantSecret.noServer, asked: checks) {
                $0.teams = [GrantSecretSample.list(workerOn: name)]
            }
        }
        await refused(GrantSecretSample.with(["login": .string(GrantSecretSample.password), "level": .string("read")]),
                      GrantSecret.readNeedsKey, asked: checks)
        await refused(read, GrantSecret.readsTwice, asked: checks) {
            $0.teams = [GrantSecretSample.list(twin: [GrantSecretSample.worker: "read"])]
        }
    }

    /// **The order of the checks**: of two faults in one call, the earlier check's sentence is the answer.
    @Test func theChecksOfTheAppRunInTheirOrder() async {
        let all = GrantSecretSample.with(["login": .string(GrantSecretSample.unknown), "agent": .string("manager"),
                                          "level": .string("read")])
        let aLogin = GrantSecretSample.password
        // Every fault at once: the reading first, and then one fault less at each step.
        await refused(all, GrantSecret.notReady, asked: ["ready"]) {
            $0.ready = false; $0.signs = false; $0.teams = [nil]; $0.vault = nil; $0.holdsKey = false
        }
        await refused(all, GrantSecret.noSignedGrants, asked: ["ready", "signs"]) {
            $0.signs = false; $0.teams = [nil]; $0.vault = nil; $0.holdsKey = false
        }
        await refused(all, GrantSecret.teamUnread, asked: ["ready", "signs", "team"]) {
            $0.teams = [nil]; $0.vault = nil; $0.holdsKey = false
        }
        let reads = ["ready", "signs", "team", "vault"]
        await refused(all, GrantSecret.vaultUnread, asked: reads) { $0.vault = nil; $0.holdsKey = false }
        await refused(all, GrantSecret.noFleet, asked: reads) {
            $0.vault = .init(fleet: nil, central: .noReading); $0.holdsKey = false
        }
        await refused(all, GrantSecret.noVaultReading, asked: reads) {
            $0.vault = .init(fleet: GrantSecretSample.fleet, central: .noReading); $0.holdsKey = false
        }
        await refused(all, GrantSecret.vaultSilent, asked: reads) {
            $0.vault = .init(fleet: GrantSecretSample.fleet, central: .silent); $0.holdsKey = false
        }
        await refused(all, GrantSecret.noOwnerKey, asked: checks) { $0.holdsKey = false }
        // The secret before the agent, the agent before its role, the role before its server, and then `read`.
        await refused(all, GrantSecret.noSecret, asked: checks)
        await refused(GrantSecretSample.with(["agent": .string("nobody"), "level": .string("read"),
                                              "login": .string(aLogin)]), GrantSecret.noAgent, asked: checks)
        await refused(GrantSecretSample.with(["agent": .string("manager"), "level": .string("read"),
                                              "login": .string(aLogin)]), GrantSecret.notWorker, asked: checks)
        await refused(GrantSecretSample.with(["login": .string(aLogin), "level": .string("read")]),
                      GrantSecret.noServer, asked: checks) { $0.teams = [GrantSecretSample.list(workerOn: nil)] }
        // A login is refused as a login, also when the agent reads a key.
        await refused(GrantSecretSample.with(["login": .string(aLogin), "level": .string("read")]),
                      GrantSecret.readNeedsKey, asked: checks) {
            $0.teams = [GrantSecretSample.list(twin: [GrantSecretSample.worker: "read"])]
        }
    }

    /// **The door is never a holder of this tool.** Its name is refused as an agent that the fleet does not have,
    /// in a give and in a take-back, also when the team's read has an agent of that name: the hub would read the
    /// name as the door's own grant. The desk is never asked to sign for it, and never to write for it.
    @Test func theDoorIsNeverAHolder() async {
        #expect(GrantSecret.door == DoorAccess.holder)
        let levels: [JSONValue] = [.string("use"), .string("read"), .null]
        for level in levels {
            let fields = GrantSecretSample.with(["agent": .string(DoorAccess.holder), "level": level])
            await refused(fields, GrantSecret.noAgent, asked: checks)
            // A team whose read has an agent of that name, with a worker's role and a server.
            await refused(fields, GrantSecret.noAgent, asked: checks) {
                var agents = GrantSecretSample.list().agents
                agents[DoorAccess.holder] = .init(role: "worker", machine: DoorAccess.holder)
                $0.teams = [GrantSecret.Team(secrets: GrantSecretSample.list().secrets, agents: agents)]
            }
        }
    }

    // ------------------------------------------------------------ one call at a time, and a caller that goes

    /// **One call writes at a time.** While the first write of a call waits, another call is refused with `busy`
    /// and sends nothing; its own checks ran. When the first call answered, the next one goes.
    @Test func aCallIsRefusedWhileAnotherIsAtItsWrites() async throws {
        let app = StandInGrantDesk()
        app.holdAt = ["sign"]
        let first = app.call(give)
        #expect(await comes { app.holds("sign") == 1 })
        #expect(app.line.busy && app.asked == checks + ["sign grant web-1"])
        // A second call, a give or a take-back: its checks run, and no write of its own is called.
        for fields in [GrantSecretSample.with(["agent": .string("lead-1")]), takeBack] {
            let answer = await app.answer(fields)
            #expect(answer == .refused(GrantSecret.busy))
        }
        #expect(app.asked == checks + ["sign grant web-1"] + checks + checks)
        #expect(app.statements.count == 1 && app.grants.isEmpty && app.line.busy)
        app.holdAt = []
        app.open("sign")
        let went = await first.value
        #expect(fields(went)?["signed"] == JSONValue.bool(true))
        #expect(!app.line.busy && app.grants == ["\(key) \(worker) use"])
        // The line is free again: the next call writes.
        let next = await app.result(takeBack)
        #expect(next?["signed"] == JSONValue.bool(true))
        #expect(app.grants.count == 2 && app.statements.count == 2 && !app.line.busy)
        // A call whose write the hub refused leaves the line free too.
        app.signAnswers = [SaveBotToken.HubFailure.refused(400, "older")]
        let last = await app.refusal(give)
        #expect(last != nil && !app.line.busy)
    }

    /// **A caller that went away before the first write sends nothing.** The call's task is cancelled during one
    /// of its two reads, as the end of its connection does: the checks pass, and neither write is called.
    @Test func aCallerThatWentAwayBeforeTheFirstWriteSendsNothing() async {
        for fields in [give, takeBack] {
            for place in ["team", "vault"] {
                let app = StandInGrantDesk()
                app.cancelAt = place
                let answer = await app.call(fields).value
                #expect(answer == .refused(GrantSecret.ended), "\(place)")
                #expect(app.asked == checks && app.writes == 0 && app.refreshes == 0 && !app.line.busy, "\(place)")
            }
        }
    }

    /// **From its first write on, a call goes to its end also when its caller went away.** The first write of a
    /// give waits; the caller's task is cancelled; the write goes on, and the second write still runs, one time.
    /// The call itself ends with the answer of a call whose writes all went, and no write saw a cancel: the writes
    /// run in a task of the line's own. The same for a take-back, whose first write is the hub's end, and for a
    /// give whose grant the hub refuses after its caller went.
    @Test func aCallerThatWentAwayAfterTheFirstWriteStillGetsTheSecondWrite() async throws {
        let app = StandInGrantDesk()
        app.holdAt = ["sign"]
        let call = app.call(give)
        #expect(await comes { app.holds("sign") == 1 })
        #expect(app.statements.count == 1 && app.grants.isEmpty)
        call.cancel()
        // The cancel ended nothing: the first write still waits, and the line is still the call's.
        for _ in 0..<5 { await Task.yield() }
        #expect(app.holds("sign") == 1 && app.line.busy && call.isCancelled)
        app.open("sign")
        let ended = await call.value
        let answer = try #require(fields(ended))
        #expect(answer["signed"] == JSONValue.bool(true) && answer["server"] == JSONValue.string("web-1"))
        #expect(app.asked == checks + ["sign grant web-1", "grant use", "refresh"])
        #expect(app.grants == ["\(key) \(worker) use"] && app.statements.count == 1 && !app.line.busy)
        let writes = app.steps.filter { ["sign", "grant"].contains($0.name) }
        #expect(writes.map(\.name) == ["sign", "grant"])
        #expect(writes.allSatisfy { !$0.cancelled }, "\(writes)")

        // A take-back: the hub's end waits, the caller goes, and the signed end still runs one time.
        let back = StandInGrantDesk()
        back.holdAt = ["grant"]
        let second = back.call(takeBack)
        #expect(await comes { back.holds("grant") == 1 })
        second.cancel()
        back.open("grant")
        let taken = await second.value
        #expect(fields(taken)?["signed"] == JSONValue.bool(true))
        #expect(back.asked == checks + ["grant null", "sign ungrant", "refresh"])
        #expect(back.statements.count == 1 && back.grants.count == 1)
        #expect(back.steps.filter { ["sign", "grant"].contains($0.name) }.allSatisfy { !$0.cancelled })

        // A give whose grant the hub refuses after its caller went: the read and the signed end still run.
        let third = StandInGrantDesk()
        third.holdAt = ["sign"]
        third.grantAnswers = [SaveBotToken.HubFailure.refused(409, "no")]
        let lost = third.call(give)
        #expect(await comes { third.holds("sign") == 1 })
        lost.cancel()
        third.holdAt = []
        third.open("sign")
        let said = await lost.value
        #expect(said == .refused(GrantSecret.withHubWords(GrantSecret.grantRefusedTakenBack, status: 409, "no")))
        #expect(third.asked == checks + ["sign grant web-1", "grant use", "team", "sign ungrant"])
        #expect(third.steps.dropFirst(2).allSatisfy { !$0.cancelled }, "\(third.steps)")
    }

    // ------------------------------------------------------------ when a write fails

    /// **A give, the signed statement.** A certain refusal: nothing was changed, with the hub's words, and the
    /// list is not asked. Not known: the same call again. A key that this Mac holds and that the app could not
    /// sign with (the desk's `NotSigned`): nothing was sent, in words that do not say that this Mac holds no key,
    /// and never "not known".
    @Test func aGiveWhoseSignedStatementFails() async {
        let certain: [(Int, String)] = [(400, "statement is older than the one that the vault holds"),
                                        (409, "hub changed"), (403, "this is not the owner machine"), (404, "not found")]
        for (status, said) in certain {
            let app = StandInGrantDesk()
            app.signAnswers = [SaveBotToken.HubFailure.refused(status, said)]
            let answer = await app.answer(give)
            #expect(answer == .refused("The hub refused the owner's signed grant, so nothing was changed. The hub's "
                                       + "words (status \(status)): \(said)"))
            #expect(app.asked == checks + ["sign grant web-1"] && app.grants.isEmpty && app.refreshes == 0)
        }
        for failure in GrantSecretSample.notKnown {
            let app = StandInGrantDesk()
            app.signAnswers = [failure]
            let answer = await app.answer(give)
            #expect(answer == .refused(GrantSecret.signNotKnown), "\(failure)")
            #expect(app.asked == checks + ["sign grant web-1"] && app.grants.isEmpty, "\(failure)")
        }
        let app = StandInGrantDesk()
        app.signAnswers = [GrantSecret.NotSigned()]
        let answer = await app.answer(give)
        #expect(answer == .refused("This Mac held an owner key for this fleet a moment ago, and the app could not "
                                   + "sign with it now: the Mac can be locked, the key can be gone, or macOS did not "
                                   + "let the app read it. Nothing was sent. Call grant_secret again later."))
        #expect(answer != .refused(GrantSecret.noOwnerKey) && answer != .refused(GrantSecret.signNotKnown))
        // The desk was asked to sign one time, and nothing after it: no grant of the hub, no read and no refresh.
        #expect(app.asked == checks + ["sign grant web-1"] && app.grants.isEmpty && app.refreshes == 0)
        #expect(!app.line.busy)
        // The same call later, when the key can sign, goes.
        app.signAnswers = [nil]
        let later = await app.result(give)
        #expect(later?["signed"] == JSONValue.bool(true))
        // A Mac that holds no key is told so before any write, in the other words.
        let none = StandInGrantDesk()
        none.holdsKey = false
        let refusal = await none.answer(give)
        #expect(refusal == .refused(GrantSecret.noOwnerKey) && none.writes == 0)
    }

    /// **A give, the statement taken, then the hub's grant refused for certain.** The app reads the team one time
    /// more and decides by that read alone. No grant of this secret for this agent there: the signed `ungrant`
    /// goes, and nothing is changed; when it fails, a signed grant stays. A grant there, at any level: no
    /// `ungrant`. A read that failed: no `ungrant`. A status of 409 is a refusal as each other status under 500.
    @Test func aGiveWhoseGrantTheHubRefuses() async {
        let hubs = "This agent already reads another key named EXAMPLE_API_KEY."
        let toTheRefusal = checks + ["sign grant web-1", "grant use"]
        // The second read has no grant: the signed end, and nothing is changed.
        for status in [400, 404, 409, 422, 499] {
            let app = StandInGrantDesk()
            app.grantAnswers = [SaveBotToken.HubFailure.refused(status, hubs)]
            let answer = await app.answer(give)
            #expect(answer == .refused("The hub refused the grant, and the app took the owner's signature of it "
                                       + "back: the fleet's list has no grant of this secret for this agent, and the "
                                       + "vault no signed grant of it for this agent. The hub's words (status "
                                       + "\(status)): \(hubs)"), "\(status)")
            #expect(app.asked == toTheRefusal + ["team", "sign ungrant"], "\(status)")
            #expect(app.statements.count == 2 && app.ungrants == 1 && app.refreshes == 0, "\(status)")
            #expect(app.statements.last == GrantSecret.Statement(fleet: fleet, login: key, agent: worker, machine: nil))
        }
        // The signed end fails, in each way: a signed grant stays, and the words name the call that ends it.
        var failures = GrantSecretSample.notKnown
        failures.append(SaveBotToken.HubFailure.refused(400, "older"))
        failures.append(GrantSecret.NotSigned())
        for failure in failures {
            let app = StandInGrantDesk()
            app.grantAnswers = [SaveBotToken.HubFailure.refused(409, hubs)]
            app.signAnswers = [nil, failure]
            let answer = await app.answer(give)
            #expect(answer == .refused(GrantSecret.withHubWords(GrantSecret.grantRefusedSignatureLeft, status: 409, hubs)),
                    "\(failure)")
            #expect(app.asked == toTheRefusal + ["team", "sign ungrant"], "\(failure)")
        }
        // The second read has a grant of this secret for this agent, at any level: no signed end.
        for level in ["use", "read", "another word"] {
            let app = StandInGrantDesk()
            app.grantAnswers = [SaveBotToken.HubFailure.refused(409, hubs)]
            app.teams = [GrantSecretSample.list(), GrantSecretSample.list(grants: [worker: level])]
            let answer = await app.answer(give)
            #expect(answer == .refused("The hub refused this call. The fleet's list has a grant of this secret for "
                                       + "this agent, which stays as it is, and the owner's signature stands for "
                                       + "it. The hub's words (status 409): \(hubs)"), "\(level)")
            #expect(app.asked == toTheRefusal + ["team"] && app.ungrants == 0 && app.statements.count == 1, "\(level)")
        }
        // The second read failed: no signed end, and the words say what can be left.
        let unread = StandInGrantDesk()
        unread.grantAnswers = [SaveBotToken.HubFailure.refused(409, hubs)]
        unread.teams = [GrantSecretSample.list(), nil]
        let answer = await unread.answer(give)
        #expect(answer == .refused(GrantSecret.withHubWords(GrantSecret.grantRefusedListUnread, status: 409, hubs)))
        #expect(unread.asked == toTheRefusal + ["team"] && unread.ungrants == 0 && unread.statements.count == 1)
    }

    /// **The read after the refusal decides alone, never the call's first read.** The first read had a grant and
    /// the second has none: the signed end goes. The first had none and the second has one (the owner's own Give
    /// in the app, between the two): no signed end, so the signature that a real grant needs stays. A grant of
    /// the same secret for another agent, and of another secret for this agent, is no grant of this one.
    @Test func theReadAfterTheRefusalDecidesAlone() async {
        let refused = SaveBotToken.HubFailure.refused(400, "no")
        let toTheRefusal = checks + ["sign grant web-1", "grant read"]
        let takenBack = OwnerChannel.Answer.refused(GrantSecret.withHubWords(GrantSecret.grantRefusedTakenBack,
                                                                             status: 400, "no"))
        let had = StandInGrantDesk()
        had.grantAnswers = [refused]
        had.teams = [GrantSecretSample.list(grants: [worker: "use"]), GrantSecretSample.list()]
        let first = await had.answer(read)
        #expect(first == takenBack)
        #expect(had.asked == toTheRefusal + ["team", "sign ungrant"])
        let came = StandInGrantDesk()
        came.grantAnswers = [refused]
        came.teams = [GrantSecretSample.list(), GrantSecretSample.list(grants: [worker: "use"])]
        let second = await came.answer(read)
        #expect(second == .refused(GrantSecret.withHubWords(GrantSecret.grantRefusedListHasOne, status: 400, "no")))
        #expect(came.asked == toTheRefusal + ["team"] && came.statements.count == 1)
        // Another agent's grant of this secret, and this agent's grant of the twin: the signed end goes.
        let others = StandInGrantDesk()
        others.grantAnswers = [refused]
        others.teams = [GrantSecretSample.list(),
                        GrantSecretSample.list(grants: ["lead-1": "read"], twin: [worker: "use"])]
        let third = await others.answer(read)
        #expect(third == takenBack)
        #expect(others.asked == toTheRefusal + ["team", "sign ungrant"])
        // The secret left the list between the two reads: no grant of it is there, so the signed end goes.
        let gone = StandInGrantDesk()
        gone.grantAnswers = [refused]
        gone.teams = [GrantSecretSample.list(),
                      GrantSecret.Team(secrets: [:], agents: GrantSecretSample.list().agents)]
        let fourth = await gone.answer(read)
        #expect(fourth == takenBack)
        #expect(gone.statements.count == 2 && gone.ungrants == 1)
    }

    /// **A give, the statement taken, then the hub's grant with no known outcome**: the app signed, whether the
    /// list has the grant is not known, and the app reads nothing more and ends no signature.
    @Test func aGiveWhoseGrantIsNotKnown() async {
        for failure in GrantSecretSample.notKnown {
            let app = StandInGrantDesk()
            app.grantAnswers = [failure]
            let answer = await app.answer(give)
            #expect(answer == .refused(GrantSecret.grantNotKnown), "\(failure)")
            #expect(app.asked == checks + ["sign grant web-1", "grant use"], "\(failure)")
            #expect(app.statements.count == 1 && app.ungrants == 0 && app.refreshes == 0, "\(failure)")
        }
    }

    /// **A take-back.** The hub's end refused for certain: nothing was changed, with the hub's words, and no
    /// signed end goes. Not known: the same call again, and no signed end. The hub's end taken and the signed end
    /// failed, in either way: the list's grant is ended, the signed grant stays, and the same call again ends it.
    @Test func aTakeBackWhoseWritesFail() async {
        let certain: [(Int, String)] = [(404, "no such secret"), (404, "no_such_agent"), (409, "hub changed")]
        for (status, said) in certain {
            let app = StandInGrantDesk()
            app.grantAnswers = [SaveBotToken.HubFailure.refused(status, said)]
            let answer = await app.answer(takeBack)
            #expect(answer == .refused("The hub refused the end of the grant, so nothing was changed. The hub's "
                                       + "words (status \(status)): \(said)"))
            #expect(app.asked == checks + ["grant null"] && app.statements.isEmpty && app.refreshes == 0)
        }
        for failure in GrantSecretSample.notKnown {
            let app = StandInGrantDesk()
            app.grantAnswers = [failure]
            let answer = await app.answer(takeBack)
            #expect(answer == .refused(GrantSecret.endNotKnown), "\(failure)")
            #expect(app.asked == checks + ["grant null"] && app.statements.isEmpty, "\(failure)")
        }
        var failures = GrantSecretSample.notKnown
        failures.append(GrantSecret.NotSigned())
        for failure in failures {
            let app = StandInGrantDesk()
            app.signAnswers = [failure]
            let answer = await app.answer(takeBack)
            #expect(answer == .refused(GrantSecret.ungrantFailed), "\(failure)")
            #expect(app.asked == checks + ["grant null", "sign ungrant", "refresh"], "\(failure)")
        }
        let app = StandInGrantDesk()
        app.signAnswers = [SaveBotToken.HubFailure.refused(400, "the statement is older")]
        let answer = await app.answer(takeBack)
        #expect(answer == .refused(GrantSecret.ungrantFailed + " The hub's words (status 400): the statement is older"))
        // The same call again: the hub's end is no change, and the end of the signature is sent again.
        app.signAnswers = [nil]
        app.receipt = .init(changed: false)
        let again = await app.result(takeBack)
        #expect(again?["note"] == JSONValue.string(GrantSecret.noteNoGrant))
        #expect(app.statements.count == 2 && app.grants.count == 2)
    }

    /// **The signed `ungrant` of a give goes only in its one case**: after a certain refusal of the hub's grant
    /// whose later read of the list shows no grant. Every other end of a give signs one statement or none.
    @Test func theUngrantOfAGiveIsSignedOnlyInItsOneCase() async {
        let refused = SaveBotToken.HubFailure.refused(409, "no")
        let fault = SaveBotToken.HubFailure.refused(500, "no"), lost = SaveBotToken.HubFailure.noAnswer
        let plain = GrantSecretSample.list()
        let granted = GrantSecretSample.list(grants: [GrantSecretSample.worker: "use"])
        let cases: [(String, (StandInGrantDesk) -> Void)] = [
            ("a give that goes", { _ in }),
            ("a statement refused", { $0.signAnswers = [SaveBotToken.HubFailure.refused(400, "no")] }),
            ("a statement not known", { $0.signAnswers = [lost] }),
            ("a grant not known", { $0.grantAnswers = [lost] }),
            ("a grant refused with a fault of the hub", { $0.grantAnswers = [fault] }),
            ("a grant refused, a grant in the list", { $0.grantAnswers = [refused]; $0.teams = [plain, granted] }),
            ("a grant refused, the list not read", { $0.grantAnswers = [refused]; $0.teams = [plain, nil] }),
            ("a grant refused, no grant in the list", { $0.grantAnswers = [refused] }),
        ]
        var signed: [String] = []
        for (name, change) in cases {
            let app = StandInGrantDesk()
            change(app)
            _ = await app.answer(give)
            #expect(app.statements.count - app.ungrants <= 1 && app.ungrants <= 1, "\(name)")
            if app.ungrants > 0 { signed.append(name) }
        }
        #expect(signed == ["a grant refused, no grant in the list"])
    }

    /// **No refusal of the app quotes what the caller sent**: the marker as an agent's name (which has a name's
    /// form), as a level, as a field's name and in a reference is in no refusal, before a write and after one.
    @Test func noRefusalOfTheAppQuotesWhatTheCallerSent() async {
        let app = StandInGrantDesk()
        let calls: [[String: JSONValue]] = [
            GrantSecretSample.with(["agent": .string(marker)]),
            GrantSecretSample.with(["agent": .string(marker), "level": .string("read")]),
            GrantSecretSample.with(["level": .string(marker)]),
            GrantSecretSample.with([marker: .string(marker)]),
            GrantSecretSample.with(["login": .string("bws://" + marker)]),
            GrantSecretSample.with(["login": .array([.string(marker)])]),
        ]
        var said: [String] = []
        for fields in calls {
            if let words = await app.refusal(fields) { said.append(words) }
        }
        #expect(said.count == 6 && said.allSatisfy { !$0.contains(marker) && !$0.contains("zq") })
        #expect(app.writes == 0)
        // An agent of that name that the team has: each refusal after a write says "this agent", never the name.
        var agents = GrantSecretSample.list().agents
        agents[marker] = .init(role: "worker", machine: "web-1")
        let team = GrantSecret.Team(secrets: GrantSecretSample.list().secrets, agents: agents)
        let lost = SaveBotToken.HubFailure.noAnswer
        let failing: [(signs: [(any Error)?], grants: [(any Error)?])] = [
            ([lost], [nil]), ([nil], [lost]),
            ([nil, lost], [SaveBotToken.HubFailure.refused(409, "refused by the hub")]),
        ]
        for failure in failing {
            let other = StandInGrantDesk()
            other.teams = [team]
            other.signAnswers = failure.signs
            other.grantAnswers = failure.grants
            let words = await other.refusal(GrantSecretSample.with(["agent": .string(marker)]))
            #expect(words != nil && words?.contains(marker) == false, "\(words ?? "")")
            #expect(words?.contains(GrantSecretSample.key) == false, "\(words ?? "")")
        }
    }
}

// ------------------------------------------------------------ the program

/// **The program's side of `grant_secret`**, with a stand-in link: what one call sends, that a wrong field
/// reaches no link, and what the program says when its answer is lost.
final class OwnerGrantSecretProgramTests {
    let home = Fixture.home()
    deinit { try? FileManager.default.removeItem(at: home) }

    static let answered = JSONValue.object(["login": .string(GrantSecretSample.key), "agent": .string("worker-1"),
                                            "level": .string("use"), "signed": .bool(true),
                                            "server": .string("web-1"), "changed": .bool(true),
                                            "note": .string(GrantSecret.noteDelivery)])

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

    /// **The tool is a write of the program alone, and the last one of its list but one** (`share_secret` came after
    /// it): taken by `write` and by the MCP form, refused by `call`, and no tool of `owner_mcp.py`'s table.
    @Test func theToolIsAWriteOfTheProgramAloneAndTheLastButOne() throws {
        let tools = OwnerTools(table: Fixture.table, context: context(ValueLink()))
        let tool = try #require(tools.listed.first { $0.name == GrantSecret.name })
        #expect(tool.annotations == .object(["readOnlyHint": .bool(false)]))
        #expect(OwnerTools.verb(of: tool) == .write)
        #expect(tools.listed.suffix(2).map(\.name) == [GrantSecret.name, ShareSecret.name])
        #expect(Fixture.table.tool(GrantSecret.name) == nil)
        let (status, out, _) = try run(["tools"], ValueLink())
        #expect(status == 0)
        #expect(out.dropLast().last == "write grant_secret: " + GrantSecret.tool.firstSentence)
        #expect(out.filter { $0.hasPrefix("write grant_secret") }.count == 1)
        let (one, full, _) = try run(["tools", "grant_secret"], ValueLink())
        #expect(one == 0 && full.contains(GrantSecret.tool.description))
        #expect(full.contains("From a shell: founderizer-cli write grant_secret '<json object>'"))
    }

    /// **`write` sends the three fields and no value part, and reads nothing on this Mac**: a give at each level,
    /// and a take-back with `level` as a JSON null. `call` refuses the tool, because it is a write.
    @Test func writeSendsTheThreeFieldsAndNoValuePart() throws {
        let looked = LookedInput()
        let link = ValueLink(.answer(.result(Self.answered)))
        let calls = [GrantSecretSample.give, GrantSecretSample.read, GrantSecretSample.takeBack]
        for (number, fields) in calls.enumerated() {
            let (status, out, said) = try run(["write", "grant_secret", JSONValue.object(fields).dumps()], link,
                                              input: looked.input)
            #expect(status == 0 && said.isEmpty && JSONValue.parse(out.joined()) == Self.answered)
            #expect(link.all.count == number + 1)
            #expect(link.all.last?.0 == OwnerChannel.Request(set: "owner", tool: "grant_secret", fields: fields))
            #expect(link.all.last?.1 == nil && link.all.last?.0.valueBytes == nil)
        }
        // The take-back's null is on the wire as a null, and the app's read of the line has it.
        let line = try #require(link.all.last?.0.line)
        let read = try OwnerChannel.Request.read(Data(line.dropLast())).get()
        #expect(read.fields == GrantSecretSample.takeBack && read.fields["level"] == JSONValue.null)
        #expect(looked.count == 0)
        let (refused, _, words) = try run(["call", "grant_secret", JSONValue.object(GrantSecretSample.give).dumps()], link)
        #expect(refused == 1 && words == ["grant_secret writes, so founderizer-cli call does not take it: run "
                                          + "founderizer-cli write grant_secret '<json object>'. The owner's client "
                                          + "asks before each write."])
        #expect(link.all.count == 3)
    }

    /// **A call with a wrong field reaches no link**: each refusal of the fields is the program's own, in the
    /// tool's fixed sentence, and nothing is sent.
    @Test func aWrongFieldReachesNoLink() throws {
        let key = GrantSecretSample.key
        let give = GrantSecretSample.give
        let cases: [([String: JSONValue], String)] = [
            ([:], GrantSecret.loginWord),
            (give.filter { $0.key != "level" }, GrantSecret.needsLevel),
            (give.merging(["level": .string("write")]) { $1 }, GrantSecret.levelWord),
            (give.merging(["level": .bool(false)]) { $1 }, GrantSecret.levelWord),
            (give.merging(["login": .string("secret:" + key)]) { $1 }, GrantSecret.loginWord),
            (give.merging(["login": .string(key.uppercased())]) { $1 }, GrantSecret.loginWord),
            (give.merging(["agent": .string("Worker 1")]) { $1 }, GrantSecret.agentWord),
            (give.merging(["request_id": .string("x")]) { $1 }, GrantSecret.only),
            (give.merging(["value": .string("x")]) { $1 }, OwnerLinkTools.neverAField),
            (["resource": .string("secret:" + key), "agent": .string("worker-1"), "level": .string("use")],
             GrantSecret.only),
        ]
        for (fields, words) in cases {
            let link = ValueLink(.answer(.result(Self.answered)))
            let (status, _, said) = try run(["write", "grant_secret", JSONValue.object(fields).dumps()], link)
            #expect(status == 1 && link.all.isEmpty, "\(fields)")
            #expect(said == [words], "\(fields)")
        }
        let link = ValueLink()
        let tools = OwnerTools(table: Fixture.table, context: context(link))
        #expect(tools.call("grant_secret", .array([])) == ("grant_secret takes one JSON object of its fields. Nothing "
                                                           + "was sent.", true))
        #expect(tools.call("grant_secret", nil) == (GrantSecret.loginWord, true))
        #expect(link.all.isEmpty)
    }

    /// **The MCP form lists the tool and takes it**, with a null `level` as a take-back, and reads nothing of its
    /// standard input.
    @Test func theMCPFormListsItAndTakesANullLevel() throws {
        let looked = LookedInput()
        let link = ValueLink(.answer(.result(Self.answered)))
        let lines = Lines()
        let mcp = OwnerMCP(tools: OwnerTools(table: Fixture.table, context: context(link, input: looked.input)),
                           version: "0.1.0", sink: { lines.add($0) })
        mcp.take(line: #"{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}"#)
        let calls = [GrantSecretSample.takeBack, GrantSecretSample.give.filter { $0.key != "level" }]
        for (number, fields) in calls.enumerated() {
            mcp.take(line: JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .int(Int64(number + 2)), "method": .string("tools/call"),
                "params": .object(["name": .string("grant_secret"), "arguments": .object(fields)]),
            ]).dumps())
        }
        mcp.finish()
        let said = lines.wait(for: 3)
        let listed = try #require(said.first { $0["id"] == .int(1) }?["result"]?["tools"]?.array)
        // The last tool but one: `share_secret` came after it.
        #expect(listed.suffix(2).map { $0["name"] } == [.string("grant_secret"), .string("share_secret")])
        let tool = try #require(listed.dropLast().last)
        #expect(tool["name"] == .string("grant_secret"))
        #expect(tool["annotations"]?["readOnlyHint"] == .bool(false))
        #expect(tool["inputSchema"]?["required"] == .array([.string("login"), .string("agent"), .string("level")]))
        let taken = try #require(said.first { $0["id"] == .int(2) }?["result"])
        #expect(taken["isError"] == .bool(false))
        #expect(link.all.count == 1 && link.all.first?.0.fields == GrantSecretSample.takeBack)
        // A call with no level is refused in the program, and no second request goes.
        let missing = try #require(said.first { $0["id"] == .int(3) }?["result"])
        #expect(missing["isError"] == .bool(true))
        #expect(missing["content"]?.array?.first?["text"] == .string(GrantSecret.needsLevel))
        #expect(looked.count == 0)
    }

    /// **A lost answer has this tool's own words**: what the app signed and wrote is not known, and the same call
    /// again is safe. An answer of the app goes back as it is, and a failure before the send keeps the link's words.
    @Test func aLostAnswerHasThisToolsOwnWords() {
        for words in [ChannelClient.noAnswer, ChannelClient.closedNoAnswer, ChannelClient.unreadable] {
            let link = ValueLink(.failed(words))
            let tools = OwnerTools(table: Fixture.table, context: context(link))
            for fields in [GrantSecretSample.give, GrantSecretSample.takeBack] {
                #expect(tools.call("grant_secret", .object(fields)) == (GrantSecret.notKnownHere, true))
            }
            #expect(link.all.count == 2)
        }
        for refusal in [GrantSecret.busy, GrantSecret.grantNotKnown, GrantSecret.ungrantFailed] {
            let tools = OwnerTools(table: Fixture.table, context: context(ValueLink(.answer(.refused(refusal)))))
            #expect(tools.call("grant_secret", .object(GrantSecretSample.give)) == (refusal, true))
        }
        let took = OwnerTools(table: Fixture.table, context: context(ValueLink(.answer(.result(Self.answered)))))
        #expect(took.call("grant_secret", .object(GrantSecretSample.give)) == (Self.answered.dumps(indent: 1), false))
        let unreached = OwnerTools(table: Fixture.table,
                                   context: context(ValueLink(.failed("This program cannot make a local socket."))))
        #expect(unreached.call("grant_secret", .object(GrantSecretSample.give))
                == ("This program cannot make a local socket.", true))
        let notRunning = OwnerTools(table: Fixture.table, context: context(ValueLink(.nothingListens)))
        #expect(notRunning.call("grant_secret", .object(GrantSecretSample.give)) == (AppLink.notStarted, true))
    }
}

// ------------------------------------------------------------ the whole way

/// **The whole way**: the program's tool, the real exchange on a socket of the test's own, the board as
/// `LinkTools.add` fills it (the set `owner`, no value part, one line of writes), and the tool's logic with a
/// stand-in desk.
final class OwnerGrantSecretLinkTests {
    let home = Fixture.home()
    let folder: URL
    let path: String

    init() {
        // Short: a local socket's path takes at most 104 bytes.
        folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fzg-\(UUID().uuidString.prefix(8))", isDirectory: true)
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

    private func wired() async -> (board: SetupBoard, desk: StandInGrantDesk, ends: CallEnds) {
        await MainActor.run {
            let app = StandInGrantDesk()
            let ends = CallEnds()
            let board = SetupBoard(read: { OwnerSetupBoardTests.facts() }, show: { _, _ in nil })
            let desk = app.desk, line = app.line
            let added = board.add(set: OwnerSetupTools.set, tool: GrantSecret.name, value: .none) { fields, value in
                let answer = await GrantSecret.answer(fields: fields, value: value, desk: desk, line: line)
                ends.all.append((answer, Task.isCancelled))
                return answer
            }
            #expect(added)
            return (board, app, ends)
        }
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

    /// **A give and a take-back go the whole way**: the program checks the fields and sends them with no value
    /// part, the app checks them again, signs and writes, and the answer comes back as the app made it. A refusal
    /// of the app comes back in its words, and a wrong field never reaches the app.
    @Test func aGiveAndATakeBackGoTheWholeWay() async throws {
        let (board, app, _) = await wired()
        let link = listener(board)
        defer { link.stop() }
        #expect(link.start() == .listening)
        let tools = tools()
        let (text, isError) = await off { tools.call("grant_secret", .object(GrantSecretSample.give)) }
        #expect(!isError, "\(text)")
        let expected: JSONValue = .object(["login": .string(GrantSecretSample.key), "agent": .string("worker-1"),
                                           "level": .string("use"), "signed": .bool(true),
                                           "server": .string("web-1"), "changed": .bool(true),
                                           "note": .string(GrantSecret.noteDelivery)])
        #expect(JSONValue.parse(text) == expected)
        var asked = await MainActor.run { app.asked }
        #expect(asked == GrantSecretSample.checks + ["sign grant web-1", "grant use", "refresh"])
        // A take-back: the null crosses the link as a null.
        let (back, backFailed) = await off { tools.call("grant_secret", .object(GrantSecretSample.takeBack)) }
        #expect(!backFailed, "\(back)")
        let taken = try #require(JSONValue.parse(back)?.object)
        #expect(taken["level"] == JSONValue.null && taken["signed"] == JSONValue.bool(true) && taken["server"] == nil)
        asked = await MainActor.run { app.asked }
        #expect(Array(asked.suffix(3)) == ["grant null", "sign ungrant", "refresh"])
        // A refusal of the app, the whole way.
        let (refused, failed) = await off {
            tools.call("grant_secret", .object(GrantSecretSample.with(["agent": .string("manager")])))
        }
        #expect(failed && refused == GrantSecret.notWorker)
        // A wrong field never reaches the app.
        let before = await MainActor.run { app.asked.count }
        let (wrong, wrongFailed) = await off {
            tools.call("grant_secret", .object(GrantSecretSample.give.filter { $0.key != "level" }))
        }
        #expect(wrongFailed && wrong == GrantSecret.needsLevel)
        let after = await MainActor.run { app.asked.count }
        #expect(after == before)
        // The board takes no value part for this tool: a raw request with one is refused before the tool runs.
        let path = path
        let part = await off {
            ChannelClient.exchange(path: path, request: .init(set: "owner", tool: GrantSecret.name,
                                                              fields: GrantSecretSample.give),
                                   value: OwnerChannel.Value(copying: Array("more".utf8)),
                                   check: StandInCheck(takes: true))
        }
        #expect(part == .answer(.refused("grant_secret takes no value part after its request line, so the app did "
                                         + "nothing.")))
        let writes = await MainActor.run { app.writes }
        #expect(writes == 4)
    }

    /// **A client that goes after its line does not stop the second write.** The caller's connection ends while
    /// the first write of a give waits: the listener frees its place and cancels the call's task. The write goes
    /// on, the hub's grant is still sent, one time, and no write saw a cancel. The call itself ended with the
    /// answer of a call whose writes all went, which nobody read, and its own task was cancelled then.
    @Test func aClientThatGoesAfterItsLineDoesNotStopTheSecondWrite() async throws {
        let (board, app, ends) = await wired()
        await MainActor.run { app.holdAt = ["sign"] }
        let link = listener(board)
        defer { link.stop() }
        #expect(link.start() == .listening)
        // A client of its own: the request line, as the program sends it. It reads no answer.
        let request = OwnerChannel.Request(set: "owner", tool: GrantSecret.name, fields: GrantSecretSample.give)
        let socket = OwnerChannel.newSocket()
        try #require(socket >= 0)
        try #require(OwnerChannel.connect(socket, to: path) == 0)
        let wire = request.line
        #expect(wire.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) } == wire.count)
        // The first write stands at the hub, and nothing else was sent.
        #expect(await comes { app.holds("sign") == 1 })
        #expect(await MainActor.run { app.statements.count == 1 && app.grants.isEmpty })
        close(socket)
        // The listener saw the close and ended the connection: its place is free.
        #expect(await comes { link.openCount == 0 })
        // The writes stand where they stood: no cancel reached them, and the call did not end.
        #expect(await MainActor.run { app.holds("sign") == 1 && app.line.busy && ends.all.isEmpty })
        // Another caller meanwhile is refused, and sends nothing.
        let tools = tools()
        let (busy, failed) = await off { tools.call("grant_secret", .object(GrantSecretSample.takeBack)) }
        #expect(failed && busy == GrantSecret.busy)
        #expect(await MainActor.run { app.writes == 1 && ends.all.count == 1 })
        // The hub answers the first write: the second one goes, with no caller.
        await MainActor.run {
            app.holdAt = []
            app.open("sign")
        }
        #expect(await comes { ends.all.count == 2 })
        let first = await MainActor.run { ends.all.last }
        #expect(first?.cancelled == true)
        guard case .result(let answer)? = first?.answer else {
            Issue.record("the call did not end with a result")
            return
        }
        #expect(answer["signed"] == .bool(true) && answer["server"] == .string("web-1"))
        let seen = await MainActor.run { (asked: app.asked, grants: app.grants, steps: app.steps, busy: app.line.busy) }
        #expect(seen.grants == ["\(GrantSecretSample.key) worker-1 use"] && !seen.busy)
        // The writes of the first call, in their order; the checks of the refused call stand between them, and it
        // wrote nothing.
        let checks = GrantSecretSample.checks
        #expect(seen.asked == checks + ["sign grant web-1"] + checks + ["grant use", "refresh"])
        let writes = seen.steps.filter { ["sign", "grant"].contains($0.name) }
        #expect(writes.map(\.name) == ["sign", "grant"])
        #expect(writes.allSatisfy { !$0.cancelled }, "\(writes)")
        // The line is free: the next call writes.
        let (next, nextFailed) = await off { tools.call("grant_secret", .object(GrantSecretSample.takeBack)) }
        #expect(!nextFailed, "\(next)")
    }
}
