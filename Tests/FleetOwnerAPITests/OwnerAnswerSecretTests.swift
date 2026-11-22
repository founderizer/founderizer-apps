import Darwin
import Foundation
import Testing
@testable import FleetCore
@testable import FleetOwnerAPI

// **`answer_secret_request`** (`OwnerAnswerSecret.swift`): the fields and their forms, the tool's words, the read of
// a request from the hub's state, the app's answer to one call with a stand-in desk, the line of writes that the tool
// shares with `grant_secret`, the program's side of one call, and the whole way on a socket of the test's own. The
// app's own desk (`LinkTools.answerDesk`) is in the app target, which has no tests. No test reads a Keychain, signs
// anything, reaches a hub or sleeps for a fixed time: a test waits with a bound of looks.

/// What the tests of `answer_secret_request` share: an example fleet, example requests and example calls.
enum AnswerSecretSample {
    static let fleet = GrantSecretSample.fleet
    static let database = "gen-1"
    /// An API key of the list, another API key of the same variable name, a key of another name, a login, a login
    /// of another site, and a reference of no secret.
    static let key = SaveSecretSample.reference
    static let twin = "bws://aaaaaaaa-bbbb-4ccc-8ddd-ffffffffffff"
    static let otherKey = "bws://22222222-3333-4444-8555-666666666666"
    static let password = "bws://11111111-2222-4333-8444-555555555555"
    static let otherPassword = "bws://33333333-4444-4555-8666-777777777777"
    static let unknown = "bws://99999999-9999-4999-8999-999999999999"
    static let need = 12
    static let variable = "EXAMPLE_API_KEY"
    static let site = "https://dashboard.example.com/login"

    /// The fleet's list: the secrets, with the grants of the key and of its twin, and the agents: three workers
    /// (their names in byte order: atlas, nova, orion), a lead, and the manager.
    static func list(grants: [String: String] = [:], twin held: [String: String] = [:]) -> GrantSecret.Team {
        GrantSecret.Team(
            secrets: [key: .init(apiKey: true, env: variable, title: variable, grants: grants),
                      twin: .init(apiKey: true, env: variable, title: variable, grants: held),
                      otherKey: .init(apiKey: true, env: "OTHER_API_KEY", title: "OTHER_API_KEY"),
                      password: .init(apiKey: false, title: "dashboard.example.com · ops@example.com"),
                      otherPassword: .init(apiKey: false, title: "mail.example.com · ops@example.com")],
            agents: ["nova": .init(role: "worker", machine: "w5"), "atlas": .init(role: "worker", machine: "w6"),
                     "orion": .init(role: "worker", machine: "w7"), "lead-1": .init(role: "lead", machine: "w8"),
                     "manager": .init(role: "manager", machine: "hub")])
    }

    /// An open request for the API key of the sample's variable name.
    static let asksKey = AnswerSecret.Request(env: variable)
    /// An open request for a login of the sample's site.
    static let asksLogin = AnswerSecret.Request(apiKey: false, site: site)

    static func call(_ login: String = key, give: [String: String] = ["nova": "use"],
                     need: Int = need) -> [String: JSONValue] {
        ["need": .int(Int64(need)), "login": .string(login), "give": .object(give.mapValues(JSONValue.string))]
    }

    /// One give, to the worker nova at `use`.
    static let one = call()
    /// No give: the answer alone.
    static let none = call(give: [:])
    /// Three gives, which go in the order atlas, nova, orion.
    static let three = call(give: ["orion": "use", "atlas": "use", "nova": "read"])

    static func with(_ more: [String: JSONValue]) -> [String: JSONValue] { one.merging(more) { $1 } }

    static func refusal(_ fields: [String: JSONValue]) -> String? {
        if case .failure(let refusal) = AnswerSecret.read(fields) { return refusal.text }
        return nil
    }

    /// The checks before the writes, as the desk is asked for a call with a give that passes them, and for a call
    /// with no give.
    static let checks = ["ready", "signs", "request", "team", "vault", "key"]
    static let checksOfNoGive = ["ready", "request", "team"]

    /// Each fixed sentence of the tool for a refusal before its first write that names no agent.
    static let before = [AnswerSecret.only, AnswerSecret.noPart, AnswerSecret.needWord, AnswerSecret.loginWord,
                         AnswerSecret.needsGive, AnswerSecret.giveWord, AnswerSecret.giveMany,
                         AnswerSecret.giveAgentWord, AnswerSecret.giveLevelWord, AnswerSecret.notReady,
                         AnswerSecret.noSignedGrants, AnswerSecret.requestUnread, AnswerSecret.teamUnread,
                         AnswerSecret.vaultUnread, AnswerSecret.noRequest, AnswerSecret.notSecretRequest,
                         AnswerSecret.answeredWithThis, AnswerSecret.answeredAlready, AnswerSecret.doorNeedsDoor,
                         AnswerSecret.doorUsesOnly, AnswerSecret.doorNotAsked, AnswerSecret.doorKeyAlone,
                         AnswerSecret.answeredWithThisForDoor,
                         AnswerSecret.noSecret, AnswerSecret.notFitting, AnswerSecret.noFleet,
                         AnswerSecret.noVaultReading, AnswerSecret.vaultSilent, AnswerSecret.noOwnerKey,
                         AnswerSecret.clockApart, AnswerSecret.busy, AnswerSecret.ended]

    /// Each sentence for one agent before a write, with an example agent.
    static func ofAgent(_ agent: String) -> [String] {
        [AnswerSecret.noAgent(agent), AnswerSecret.notWorker(agent), AnswerSecret.noServer(agent),
         AnswerSecret.readNeedsKey(agent), AnswerSecret.readsTwice(agent)]
    }

    /// Each end of a give that stops a call, with the hub's status and words where the end has them.
    static let stops: [GrantSecret.GiveEnd] = [
        .notSignedNow, .signRefused(400, "older"), .signNotKnown, .grantNotKnown, .refusedTakenBack(409, "no"),
        .refusedSignatureLeft(409, "no"), .refusedListHasOne(409, "no"), .refusedListUnread(409, "no"),
    ]

    /// Each sentence after a write, with example agents.
    static func after(_ agents: [String]) -> [String] {
        stops.map { AnswerSecret.stopped($0, agent: "nova", before: agents) }
            + [AnswerSecret.hadAnswerWithThis(agents), AnswerSecret.closedFirst(agents),
               AnswerSecret.answeredUnread(agents), AnswerSecret.answerRefused(agents),
               AnswerSecret.answerNotKnown(agents)]
    }

    /// The bytes of a hub's state with these Needs-you items.
    static func state(db: Any? = database, needs: Any? = [[String: Any]]()) -> Data {
        var state: [String: Any] = ["schema_version": 1, "time": 1_794_000_000]
        if let db { state["db"] = db }
        if let needs { state["needs"] = needs }
        return try! JSONSerialization.data(withJSONObject: state)
    }

    /// One Needs-you item as the hub's state has it.
    static func item(id: Any = need, kind: String = "secret", answer: Any = NSNull(),
                     secret: Any? = ["kind": "api_key", "env": variable]) -> [String: Any] {
        var item: [String: Any] = ["id": id, "kind": kind, "answer": answer, "title": "A key for the example",
                                   "by": "nova"]
        if let secret { item["secret"] = secret }
        return item
    }
}

/// **The app's engine for `answer_secret_request` as stand-ins**: the fleet as the app reads it, the hub's answer to
/// each write, and a record of what the desk was asked, in its order.
@MainActor
final class StandInAnswerDesk {
    typealias Place = StandInGrantDesk.Place
    typealias Step = StandInGrantDesk.Step

    // The fleet, as the app reads it.
    var ready = true
    var signs: Bool? = true
    /// What each read of the request gives, in the order of the reads: a reading, or nil for a read that fails.
    /// The last one serves each later read too.
    var requests: [AnswerSecret.RequestRead?] = [.found(AnswerSecretSample.asksKey)]
    var teams: [GrantSecret.Team?] = [AnswerSecretSample.list()]
    var vault: GrantSecret.Vault? = GrantSecret.Vault(fleet: AnswerSecretSample.fleet, central: .answers)
    var holdsKey = true
    /// Whether this Mac's clock and the hub's differ by more than an hour, or nil for no answer of the hub in this
    /// launch. It is not recorded in `asked`: `clockAsked` says whether a call asked it.
    var clockApart: Bool? = false
    var clockAsked = false
    /// What each signed statement, each grant of the hub and each answer gets, in the order of the sends: nil when
    /// it was taken. The last one serves each later send too.
    var signAnswers: [(any Error)?] = [nil]
    var grantAnswers: [(any Error)?] = [nil]
    var answerAnswers: [(any Error)?] = [nil]
    var receipt = GrantSecret.Receipt(changed: true)

    // What the desk was asked.
    var asked: [String] = []
    var statements: [GrantSecret.Statement] = []
    var grants: [String] = []
    var answers: [String] = []
    var needsRead: [Int] = []
    var refreshes = 0
    var steps: [Step] = []
    /// The closure whose call cancels the task that called it, as the end of the call's connection does.
    var cancelAt: String?
    /// The closures that stop until the test opens them, and the calls that stand there now.
    var holdAt: Set<String> = []
    private var held: [(name: String, go: CheckedContinuation<Void, Never>)] = []

    let line: GrantSecret.Line

    init(line: GrantSecret.Line = GrantSecret.Line()) { self.line = line }

    /// The writes that the desk was asked for: the signed statements, the hub's grants and the answers.
    var writes: Int { statements.count + grants.count + answers.count }

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

    private func next<Answer>(_ answers: inout [Answer]) -> Answer? {
        guard let first = answers.first else { return nil }
        if answers.count > 1 { answers.removeFirst() }
        return first
    }

    var desk: AnswerSecret.Desk<Place> {
        AnswerSecret.Desk<Place>(
            ready: { [self] in
                asked.append("ready")
                return ready ? Place() : nil
            },
            signs: { [self] _ in
                asked.append("signs")
                return signs
            },
            request: { [self] _, need in
                asked.append("request")
                needsRead.append(need)
                await step("request")
                guard let found = next(&requests), let reading = found else { throw SaveBotToken.HubFailure.noAnswer }
                return reading
            },
            team: { [self] _ in
                asked.append("team")
                await step("team")
                guard let found = next(&teams), let list = found else { throw SaveBotToken.HubFailure.noAnswer }
                return list
            },
            vault: { [self] _ in
                asked.append("vault")
                await step("vault")
                guard let vault else { throw SaveBotToken.HubFailure.noAnswer }
                return vault
            },
            holdsKey: { [self] fleet in
                asked.append("key")
                return fleet == AnswerSecretSample.fleet && holdsKey
            },
            isMachine: { CentralVault.isMachine($0) },
            clockApart: { [self] _ in
                clockAsked = true
                return clockApart
            },
            sign: { [self] _, statement in
                asked.append(statement.machine.map { "sign grant \(statement.agent) \($0)" }
                             ?? "sign ungrant \(statement.agent)")
                statements.append(statement)
                await step("sign")
                if let found = next(&signAnswers), let error = found { throw error }
            },
            grant: { [self] _, login, agent, level in
                asked.append("grant \(agent) \(level.rawValue)")
                grants.append("\(login) \(agent) \(level.rawValue)")
                await step("grant")
                if let found = next(&grantAnswers), let error = found { throw error }
                return receipt
            },
            answer: { [self] _, need, login in
                asked.append("answer")
                answers.append("\(need) \(login)")
                await step("answer")
                if let found = next(&answerAnswers), let error = found { throw error }
            },
            refresh: { [self] in
                asked.append("refresh")
                refreshes += 1
            })
    }

    func answer(_ fields: [String: JSONValue], value: OwnerChannel.Value? = nil) async -> OwnerChannel.Answer {
        await AnswerSecret.answer(fields: fields, value: value, desk: desk, line: line)
    }

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

/// **The fields of `answer_secret_request`**: `need`, `login` and `give`, all three required, each in one strict form.
struct OwnerAnswerSecretFieldTests {
    let key = AnswerSecretSample.key

    private func with(_ more: [String: JSONValue]) -> [String: JSONValue] { AnswerSecretSample.with(more) }
    private func said(_ fields: [String: JSONValue]) -> String? { AnswerSecretSample.refusal(fields) }

    /// The three fields as they came, with the gives in the byte order of the agents' names, and `{}` as no give.
    @Test func theThreeFieldsAreReadAndTheGivesAreInNameOrder() {
        #expect(AnswerSecret.read(AnswerSecretSample.one)
                == .success(.init(need: 12, login: key, give: [.init(agent: "nova", level: .use)])))
        #expect(AnswerSecret.read(AnswerSecretSample.none) == .success(.init(need: 12, login: key, give: [])))
        #expect(AnswerSecret.read(AnswerSecretSample.three) == .success(.init(need: 12, login: key, give: [
            .init(agent: "atlas", level: .use), .init(agent: "nova", level: .read), .init(agent: "orion", level: .use),
        ])))
        // The byte order: a digit before a letter, "-" before both, and a shorter name before a longer one.
        let names = ["ab", "ab-1", "ab1", "aba", "b-", "b0"]
        let read = try? AnswerSecret.read(AnswerSecretSample.call(
            give: Dictionary(uniqueKeysWithValues: names.reversed().map { ($0, "use") }))).get()
        #expect(read?.give.map(\.agent) == ["ab", "ab-1", "ab1", "aba", "b-", "b0"])
        #expect(AnswerSecret.fields == ["need", "login", "give"])
    }

    /// **`need` is a JSON integer from 1 to 2147483647**: a text, a fraction, a boolean, a null, zero, a negative
    /// number and a larger one are refused.
    @Test func needIsAWholeNumberInItsBounds() {
        for good in [Int64(1), 12, 2_147_483_647] {
            #expect(said(with(["need": .int(good)])) == nil, "\(good)")
        }
        let bad: [JSONValue] = [.int(0), .int(-1), .int(2_147_483_648), .string("12"), .double(12), .double(1.5),
                                .bool(true), .null, .array([.int(12)]), .bigInt("99999999999999999999")]
        for value in bad {
            #expect(said(with(["need": value])) == AnswerSecret.needWord, "\(value)")
        }
        #expect(said(AnswerSecretSample.one.filter { $0.key != "need" }) == AnswerSecret.needWord)
    }

    /// `login` is a reference in the list's one spelling, as for `grant_secret`.
    @Test func loginIsAReference() {
        for bad: JSONValue in [.string("secret:" + key), .string(key.uppercased()), .string(key + "\n"), .string(""),
                               .int(1), .null] {
            #expect(said(with(["login": bad])) == AnswerSecret.loginWord, "\(bad)")
        }
        #expect(said(AnswerSecretSample.one.filter { $0.key != "login" }) == AnswerSecret.loginWord)
    }

    /// **`give` must be given, as an object of at most 12 agents with use or read.** A call with no `give` is
    /// refused, and is never "no agent".
    @Test func giveIsAnObjectOfAtMostTwelveAgentsWithALevel() {
        #expect(said(AnswerSecretSample.one.filter { $0.key != "give" }) == AnswerSecret.needsGive)
        for bad: JSONValue in [.null, .array([]), .string("nova"), .bool(false), .int(0)] {
            #expect(said(with(["give": bad])) == AnswerSecret.giveWord, "\(bad)")
        }
        func agents(_ count: Int) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (0..<count).map { ("agent-\($0)", "use") })
        }
        #expect(said(AnswerSecretSample.call(give: agents(12))) == nil)
        #expect(said(AnswerSecretSample.call(give: agents(13))) == AnswerSecret.giveMany)
        #expect(AnswerSecret.giveMost == 12 && AnswerSecret.giveMany.contains("at most 12 agents"))
        for name in ["Nova", "n", "1nova", "nova worker", "nova_1", String(repeating: "a", count: 32), ""] {
            #expect(said(AnswerSecretSample.call(give: [name: "use"])) == AnswerSecret.giveAgentWord, "\(name)")
        }
        for level: JSONValue in [.string("write"), .string("Use"), .string(""), .null, .bool(true), .int(1),
                                 .object([:])] {
            #expect(said(with(["give": .object(["nova": level])])) == AnswerSecret.giveLevelWord, "\(level)")
        }
        // One wrong level beside good ones is refused, whatever the order of the object's keys.
        #expect(said(AnswerSecretSample.call(give: ["atlas": "use", "nova": "read", "orion": "all"]))
                == AnswerSecret.giveLevelWord)
    }

    /// **The checks run in a fixed order**: a field named like a value, an unknown field, `need`, `login`, and
    /// then `give`: absent, no object, too many, a name, a level.
    @Test func theChecksOfTheFieldsRunInTheirOrder() {
        let many = Dictionary(uniqueKeysWithValues: (0..<13).map { ("Agent \($0)", JSONValue.int(1)) })
        var fields: [String: JSONValue] = ["token": .string("x"), "more": .int(1), "need": .string("12"),
                                           "login": .string("x"), "give": .object(many)]
        #expect(said(fields) == OwnerLinkTools.neverAField)
        fields["token"] = nil
        #expect(said(fields) == AnswerSecret.only)
        fields["more"] = nil
        #expect(said(fields) == AnswerSecret.needWord)
        fields["need"] = .int(12)
        #expect(said(fields) == AnswerSecret.loginWord)
        fields["login"] = .string(key)
        #expect(said(fields) == AnswerSecret.giveMany)
        fields["give"] = .object(["Nova": .int(1), "atlas": .string("all")])
        #expect(said(fields) == AnswerSecret.giveAgentWord)
        fields["give"] = .object(["nova": .int(1)])
        #expect(said(fields) == AnswerSecret.giveLevelWord)
        fields["give"] = .string("nova")
        #expect(said(fields) == AnswerSecret.giveWord)
        fields["give"] = nil
        #expect(said(fields) == AnswerSecret.needsGive)
        // Each field named like a value, whatever it holds, and a field of another tool.
        for name in ["value", "password", "api_key", "Token", "secret"] {
            #expect(said(with([name: .string("x")])) == OwnerLinkTools.neverAField, "\(name)")
        }
        for name in ["agent", "level", "decline", "request_id", "from", "path"] {
            #expect(said(with([name: .string("x")])) == AnswerSecret.only, "\(name)")
        }
    }

    /// **The plan sends the three fields as the read took them**: `need` as an integer and `give` as an object of
    /// the levels' words. A refusal of the fields is the plan's refusal.
    @Test func thePlanSendsTheThreeFields() throws {
        #expect(try AnswerSecret.plan(AnswerSecretSample.one).get() == AnswerSecretSample.one)
        #expect(try AnswerSecret.plan(AnswerSecretSample.none).get() == AnswerSecretSample.none)
        let three = try AnswerSecret.plan(AnswerSecretSample.three).get()
        #expect(three == AnswerSecretSample.three && three["need"] == .int(12))
        #expect(three["give"] == .object(["atlas": .string("use"), "nova": .string("read"), "orion": .string("use")]))
        #expect(AnswerSecret.plan(with(["need": .string("12")])) == .failure(.init(AnswerSecret.needWord)))
    }

    /// **No refusal of the fields quotes anything of the request**: a marker as a field's name, as an id, in a
    /// reference, as an agent's name of a wrong form and as a level is in no refusal.
    @Test func theRefusalsOfTheFieldsQuoteNothing() {
        let marker = "zq-marker"
        let calls: [[String: JSONValue]] = [
            with([marker: .string(marker)]), with(["need": .string(marker)]),
            with(["login": .string("bws://" + marker)]), with(["give": .string(marker)]),
            with(["give": .object(["Zq-Marker": .string("use")])]), with(["give": .object(["nova": .string(marker)])]),
            with(["give": .object([marker: .string(marker)])]),
        ]
        for fields in calls {
            let words = said(fields)
            #expect(words != nil && words?.lowercased().contains("zq") == false, "\(words ?? "")")
        }
    }

    /// The bound of `give` is the hub's own bound of a request's proposal, where this repository has the hub's file.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: OwnerGrantSecretFieldTests.hub.path)))
    func theBoundOfGiveIsTheHubsOwn() throws {
        let source = try String(contentsOf: OwnerGrantSecretFieldTests.hub, encoding: .utf8)
        #expect(source.contains("\nSECRET_GIVE_MAX = \(AnswerSecret.giveMost)\n"))
        #expect(source.contains(#"raise Refusal(409, code="request_answered")"#))
        // The door's own proposal (a door key's request gives the door "use"); since owner API 1.295 a request for a
        // new value of a key that the fleet holds comes first in the same line and proposes nothing.
        #expect(source.contains(#"{"door": "use"} if door else"#))
    }
}

// ------------------------------------------------------------ the words

/// **The words of `answer_secret_request`**: the tool as the program lists it, and its sentences.
struct OwnerAnswerSecretWordsTests {
    /// **The tool is a write with three required fields and no value, and it is listed**: the sixth and last of
    /// `OwnerLinkTools.names` and `tools`, one time in each, and no tool of `owner_mcp.py`'s table.
    @Test func theToolIsAWriteWithThreeRequiredFieldsAndIsListedLast() throws {
        let tool = AnswerSecret.tool
        #expect(tool.name == "answer_secret_request" && AnswerSecret.name == tool.name && tool.what == tool.name)
        #expect(tool.annotations == .object(["readOnlyHint": .bool(false)]))
        #expect(OwnerTools.verb(of: tool) == .write)
        #expect(tool.inputSchema["required"] == .array([.string("need"), .string("login"), .string("give")]))
        #expect(tool.inputSchema["additionalProperties"] == .bool(false))
        let properties = try #require(tool.inputSchema["properties"]?.object)
        #expect(Set(properties.keys) == Set(AnswerSecret.fields) && properties.count == 3)
        #expect(properties["need"] == .object(["type": .string("integer"), "minimum": .int(1),
                                               "maximum": .int(2_147_483_647)]))
        #expect(properties["login"] == .object(["type": .string("string")]))
        #expect(properties["give"] == .object([
            "type": .string("object"), "maxProperties": .int(12),
            "additionalProperties": .object(["type": .string("string"),
                                             "enum": .array([.string("use"), .string("read")])]),
        ]))
        #expect(tool.feature == nil && tool.route.isEmpty && !tool.requestIDFromArguments && tool.fields.isEmpty)
        #expect(tool.firstSentence == "Needs you: Answers one request of an agent for a secret with a secret that "
                + "the fleet's list has already, as Answer with it does in the Founderizer app's form of that request "
                + "on Needs you.")
        #expect(OwnerLinkTools.names == ["save_bot_token", "prepare_problem_report", "save_secret", "grant_secret",
                                         "share_secret", "answer_secret_request"])
        #expect(OwnerLinkTools.tools.map(\.name) == OwnerLinkTools.names)
        #expect(OwnerLinkTools.tools.last?.description == tool.description)
        #expect(Fixture.table.tool(AnswerSecret.name) == nil)
        let listed = OwnerTools.programTable(Fixture.table).tools.filter { $0.kind.listed }
        #expect(listed.last?.name == AnswerSecret.name)
        #expect(listed.filter { $0.name == AnswerSecret.name }.count == 1)
        #expect(OwnerLinkTools.notKnownHere(AnswerSecret.name) == AnswerSecret.notKnownHere)
        #expect(AnswerSecret.notKnownHere != OwnerLinkTools.notKnownOther)
    }

    /// What the description must say: no value, the order, the stop, the door, `read`, and the shared line.
    @Test func theDescriptionSaysWhatItMust() {
        let words = AnswerSecret.tool.description
        for part in ["and never its value", "First the app gives the secret to each agent of give with the owner's "
                     + "signature, as grant_secret does. Then the hub answers the request",
                     "give: an object that must be given, of at most 12 agents: each key an agent's name, as "
                     + "fleet_read(page=\"team\") gives it, and each value use or read. {} answers the request "
                     + "and gives the secret to no agent. The agent that asked gets the secret only when give names "
                     + "it or when it holds the secret already; the answer closes the request either way.",
                     "so give read only when the owner asked for it.",
                     "The request's own give is a proposal and no decision: answer only with the secret and the "
                     + "agents that the owner named.",
                     "the first one that fails stops the call: the gives before it stand, and the call does not "
                     + "answer the request.",
                     "A request for the door (its secret has door, or its give has the key door) is answered in "
                     + "the same way, and its give must name door with use: the app gives the secret to the door "
                     + "with the owner's signature, as the app's own form of that request does",
                     "give names door only for a request for the door.",
                     "the door has no server",
                     "A no is decline_secret_request.", "with give {} the app signs nothing.",
                     "One call of this tool or of grant_secret writes at a time",
                     "No answer has a secret's value."] {
            #expect(words.contains(part), "\(part)")
        }
        #expect(!words.contains("\n") && !words.contains("  "))
        for never in ["read a login", "reads a login", "read the secret", "reads the secret"] {
            #expect(!words.contains(never))
        }
    }

    /// **The sentences that the two tools share, and the ones that other texts point at, word for word.**
    @Test func theSharedSentencesAreHeldWordForWord() {
        #expect(AnswerSecret.busy == GrantSecret.busy)
        #expect(AnswerSecret.busy == "Another call of grant_secret or answer_secret_request is at its writes now. "
                + "Call again when it has answered. Nothing was sent.")
        #expect(AnswerSecret.answeredWithThis == "That request has its answer already, with this secret. This call "
                + "gave the secret to no agent: grant_secret gives it to an agent. Nothing was sent.")
        #expect(AnswerSecret.doorNeedsDoor == "That request is for the door, so give must name door with use, as "
                + "the request proposes: the app gives the secret to the door with the owner's signature, as its own "
                + "form of the request does. Nothing was sent.")
        #expect(AnswerSecret.doorNotAsked == "give names door, and that request is not for the door: the door gets a "
                + "secret only with the answer of a request for it. Nothing was sent.")
        #expect(AnswerSecret.notSecretRequest == "That Needs-you item asks for no secret, so this tool does not "
                + "answer it: answer_needs_you answers it, in the owner's words. Nothing was sent.")
        #expect(AnswerSecret.noSignedGrants == "This hub takes no signed grant, so the app signs nothing for it. On "
                + "such a fleet, give the secret to each agent with grant_access, and then call "
                + "answer_secret_request with give {}. Nothing was sent.")
        #expect(AnswerSecret.noVaultReading.contains("or the hub has not read it since it started"))
        #expect(AnswerSecret.noVaultReading.contains("only on a fleet that has none, give the secret to each agent "
                                                     + "with grant_access, and then call answer_secret_request with "
                                                     + "give {}."))
        #expect(!AnswerSecret.vaultSilent.contains("grant_access"))
        #expect(AnswerSecret.clockApart == "This Mac's clock and the hub's clock differ by more than an hour, so the "
                + "app signs no give now. Ask the owner to check this Mac's date and time (System Settings, General, "
                + "Date & Time), and then call answer_secret_request again with the same give. If this Mac's clock is "
                + "right, the hub's clock is probably wrong: tell the owner. Nothing was sent.")
        #expect(AnswerSecret.noAnswerYet == "This call did not answer the request.")
        #expect(AnswerSecret.answeredAlready == "That request is closed already: the owner declined it or answered "
                + "it with another secret, or an agent or the hub closed it. A request takes one answer. Nothing "
                + "was sent.")
        #expect(AnswerSecret.closedFirst(["nova"]) == "The request was closed before this call's answer came: the "
                + "owner declined it or answered it with another secret, or an agent or the hub closed it. So the "
                + "hub did not take this call's answer. This call gave the secret to: nova. Those grants stand. Ask "
                + "the owner whether those agents keep the secret: grant_secret with level null takes it back from "
                + "one agent.")
        #expect(AnswerSecret.closedFirst([]) == "The request was closed before this call's answer came: the owner "
                + "declined it or answered it with another secret, or an agent or the hub closed it. So the hub did "
                + "not take this call's answer. This call gave the secret to no agent.")
        #expect(AnswerSecret.answeredUnread([]) == "The request was closed already, and the app could not read "
                + "how. This call gave the secret to no agent.")
        #expect(AnswerSecret.answerRefused([]) == "The hub refused the answer, so this call did not answer the "
                + "request. This call gave the secret to no agent.")
        #expect(AnswerSecret.answerRefused(["nova"]) == "The hub refused the answer, so this call did not answer "
                + "the request. This call gave the secret to: nova. Those grants stand. Ask the owner whether those "
                + "agents keep the secret: grant_secret with level null takes it back from one agent.")
        #expect(AnswerSecret.gaveBefore([]) == "Before that, this call gave the secret to no agent.")
        #expect(AnswerSecret.gaveBefore(["atlas", "nova"]) == "Before that, this call gave the secret to: atlas, "
                + "nova. Those grants stand.")
        #expect(AnswerSecret.gave([]) == "This call gave the secret to no agent.")
        #expect(AnswerSecret.gave(["atlas"]) == "This call gave the secret to: atlas. Those grants stand.")
        #expect(AnswerSecret.notKnownHere.contains("not known")
                && AnswerSecret.notKnownHere.contains("Call answer_secret_request again in the same way: that is "
                                                      + "safe"))
    }

    /// **"Nothing was sent." exactly when nothing was sent**: each refusal before the first write ends with those
    /// words, one time, and no sentence after a write has them. Each sentence is one line with single spaces, and
    /// none says that an agent can read a login.
    @Test func theSentencesSayNothingWasSentExactlyWhenNothingWas() {
        let before = AnswerSecretSample.before + AnswerSecretSample.ofAgent("nova")
        let after = AnswerSecretSample.after([]) + AnswerSecretSample.after(["atlas", "lead-1"])
            + [AnswerSecret.notKnownHere, AnswerSecret.noteAnswered, AnswerSecret.noteNoGive]
        #expect(Set(before).count == before.count && Set(after).count == after.count)
        for words in before + [OwnerLinkTools.neverAField] {
            #expect(words.hasSuffix(" Nothing was sent."), "\(words)")
            #expect(words.components(separatedBy: "Nothing was sent").count == 2, "\(words)")
            for claim in ["app signed", "signed the grant", "took the owner's"] {
                #expect(!words.contains(claim), "\(words)")
            }
        }
        for words in after {
            #expect(!words.contains("Nothing was sent") && !words.contains("nothing was sent"), "\(words)")
        }
        for words in before + after {
            #expect(!words.contains("\n") && !words.contains("  ") && !words.hasSuffix(" "), "\(words)")
            for never in ["read a login", "reads a login", "read the login", "read the secret", "reads the secret"] {
                #expect(!words.contains(never), "\(words)")
            }
            // The tools of the link that this tool's words may name: itself, and the one that gives and takes back.
            for other in [SaveBotToken.name, PrepareReport.name, ShareSecret.name] {
                #expect(!words.contains(other), "\(words)")
            }
        }
        // Each sentence for one agent names it, and each stop names its agent and says that no answer went.
        for words in AnswerSecretSample.ofAgent("nova") { #expect(words.contains("nova"), "\(words)") }
        for end in AnswerSecretSample.stops {
            let words = AnswerSecret.stopped(end, agent: "nova", before: ["atlas"])
            #expect(words.contains("the agent nova") && words.contains("gave the secret to: atlas."), "\(words)")
            #expect(words.contains(AnswerSecret.noAnswerYet), "\(words)")
        }
        // The hub's own words stand last.
        let refused = AnswerSecret.stopped(.signRefused(400, "the statement is older"), agent: "nova", before: [])
        #expect(refused.hasSuffix(" The hub's words (status 400): the statement is older"))
        // A signature that stays tells the caller the one call that ends it, with its fields.
        for end in [GrantSecret.GiveEnd.refusedSignatureLeft(409, "no"), .refusedListUnread(409, "no")] {
            #expect(AnswerSecret.stopped(end, agent: "nova", before: []).lowercased()
                .contains("call grant_secret with this login, the agent nova and level null"))
        }
        #expect(AnswerSecret.stopped(.refusedListUnread(409, "no"), agent: "nova", before: [])
            .contains("If it has one, change nothing"))
        // The request was closed first, or the hub refused the answer: the tool takes nothing back, and the words
        // send the caller to the owner when a give stands. The door is no agent: grant_secret takes nothing back
        // from it.
        for words in [AnswerSecret.closedFirst, AnswerSecret.answeredUnread, AnswerSecret.answerRefused] {
            #expect(words(["nova"]).contains("Ask the owner whether those agents keep the secret"))
            #expect(!words([]).contains("Ask the owner"))
            #expect(!words(["door"]).contains("grant_secret") && words(["door"]).contains("tell the owner that the door "
                                                                                         + "keeps it."))
            #expect(words(["door", "nova"]).contains("grant_secret with level null takes it back from one agent. No "
                                                     + "tool here takes the secret back from the door"))
        }
        // No sentence says that only the owner can have closed a request.
        for words in AnswerSecretSample.before + AnswerSecretSample.after(["nova"]) {
            #expect(!words.contains("The owner's answer") && !words.contains("has no answer"), "\(words)")
        }
    }
}

// ------------------------------------------------------------ the request, from the hub's state

/// **The read of one request from the bytes of the hub's state** (`AnswerSecret.request(in:need:database:)`), on
/// real JSON, and the rule of a secret that fits.
struct OwnerAnswerSecretRequestTests {
    let need = AnswerSecretSample.need
    let database = AnswerSecretSample.database

    private func read(_ data: Data, need: Int = AnswerSecretSample.need) -> AnswerSecret.RequestRead {
        AnswerSecret.request(in: data, need: need, database: database)
    }

    private func found(_ item: [String: Any]) -> AnswerSecret.Request? {
        if case .found(let request) = read(AnswerSecretSample.state(needs: [item])) { return request }
        return nil
    }

    /// An open request for an API key and one for a login, among other items.
    @Test func anOpenRequestIsFoundWithItsFacts() {
        let other = AnswerSecretSample.item(id: 11, kind: "question", secret: nil)
        let login = AnswerSecretSample.item(id: 13, secret: ["kind": "login", "site": AnswerSecretSample.site,
                                                             "give": ["nova": "use"]])
        let data = AnswerSecretSample.state(needs: [other, AnswerSecretSample.item(), login])
        #expect(read(data) == .found(AnswerSecretSample.asksKey))
        #expect(read(data, need: 13) == .found(AnswerSecretSample.asksLogin))
        #expect(read(data, need: 11) == .found(.init(isSecret: false)))
        // The hub's default: a request that names no kind asks for an API key.
        #expect(found(AnswerSecretSample.item(secret: ["env": "EXAMPLE_API_KEY"])) == AnswerSecretSample.asksKey)
    }

    /// No item of that id; an id that is a text or a boolean is no id.
    @Test func noItemOfThatIdIsNone() {
        #expect(read(AnswerSecretSample.state()) == .none)
        #expect(read(AnswerSecretSample.state(needs: [AnswerSecretSample.item(id: 13)])) == .none)
        #expect(read(AnswerSecretSample.state(needs: [AnswerSecretSample.item(id: "12")])) == .none)
        #expect(read(AnswerSecretSample.state(needs: [AnswerSecretSample.item(id: 12.5)])) == .none)
        #expect(read(AnswerSecretSample.state(needs: [AnswerSecretSample.item(id: true)]), need: 1) == .none)
        #expect(read(AnswerSecretSample.state(needs: ["text", 12, NSNull()])) == .none)
    }

    /// A state of another database is another generation, whatever it has under that id.
    @Test func aStateOfAnotherDatabaseIsAnotherGeneration() {
        let data = AnswerSecretSample.state(db: "gen-2", needs: [AnswerSecretSample.item()])
        #expect(read(data) == .otherGeneration)
    }

    /// Bytes that are no state.
    @Test func bytesThatAreNoStateAreUnreadable() {
        #expect(read(Data()) == .unreadable)
        #expect(read(Data("not json".utf8)) == .unreadable)
        #expect(read(Data("[1, 2]".utf8)) == .unreadable)
        #expect(read(AnswerSecretSample.state(db: nil)) == .unreadable)
        #expect(read(AnswerSecretSample.state(db: 7)) == .unreadable)
        #expect(read(AnswerSecretSample.state(needs: nil)) == .unreadable)
        #expect(read(AnswerSecretSample.state(needs: ["id": 12])) == .unreadable)
    }

    /// **An answered request**: with a secret (its `saved`), with a decline (no `saved`), and a `saved` that is no
    /// reference.
    @Test func anAnsweredRequestSaysWhatAnsweredIt() {
        let key = AnswerSecretSample.key
        let saved = found(AnswerSecretSample.item(answer: "Saved as EXAMPLE_API_KEY.",
                                                  secret: ["kind": "api_key", "env": "EXAMPLE_API_KEY", "saved": key]))
        #expect(saved == .init(open: false, env: "EXAMPLE_API_KEY", saved: key))
        let declined = found(AnswerSecretSample.item(answer: "Not given."))
        #expect(declined == .init(open: false, env: "EXAMPLE_API_KEY"))
        let odd = found(AnswerSecretSample.item(answer: "x", secret: ["env": "EXAMPLE_API_KEY", "saved": "bws://X"]))
        #expect(odd?.saved == nil && odd?.open == false)
        // An item with no `answer` at all is open.
        var bare = AnswerSecretSample.item()
        bare["answer"] = nil
        #expect(found(bare)?.open == true)
    }

    /// **A request is for the door** when its secret has `door`, and also when its proposal names the door beside
    /// a worker with no `door`. A `door` that is null, and a proposal that names only agents, are not.
    @Test func aRequestIsForTheDoorByItsDoorOrByItsProposal() {
        let withDoor = found(AnswerSecretSample.item(secret: ["kind": "api_key", "env": "EXAMPLE_API_KEY",
                                                              "door": "app:web-1:shop", "give": ["door": "use"]]))
        #expect(withDoor?.door == true && withDoor?.doorKey == true)
        let doorAlone = found(AnswerSecretSample.item(secret: ["kind": "login", "site": AnswerSecretSample.site,
                                                               "door": "web-1"]))
        #expect(doorAlone?.door == true && doorAlone?.doorKey == true)
        // A proposal that names the door beside an agent asks for no key of the door: the agent can get it too.
        let proposed = found(AnswerSecretSample.item(secret: ["kind": "api_key", "env": "EXAMPLE_API_KEY",
                                                              "give": ["door": "use", "nova": "use"]]))
        #expect(proposed?.door == true && proposed?.doorKey == false)
        let agents = found(AnswerSecretSample.item(secret: ["kind": "api_key", "env": "EXAMPLE_API_KEY",
                                                            "door": NSNull(), "give": ["nova": "use"]]))
        #expect(agents?.door == false)
        // A proposal that is no object names nobody.
        let odd = found(AnswerSecretSample.item(secret: ["env": "EXAMPLE_API_KEY", "give": ["door"]]))
        #expect(odd?.door == false)
        #expect(GrantSecret.door == "door")
    }

    /// **What the read takes as it comes**: an `id` written with a fraction of zero is that whole number; a `door`
    /// that is present and not null is a door request, also an empty text and a `false` (strict on purpose); and a
    /// secret whose `kind` is no text asks for an API key, which is the hub's default.
    @Test func theReadIsStrictOnTheDoorAndTakesTheHubsDefaults() {
        let data = Data(#"{"db": "gen-1", "needs": [{"id": 12.0, "kind": "secret", "answer": null, "#.utf8)
            + Data(#""secret": {"kind": "api_key", "env": "EXAMPLE_API_KEY"}}]}"#.utf8)
        #expect(read(data) == .found(AnswerSecretSample.asksKey))
        #expect(read(data, need: 13) == AnswerSecret.RequestRead.none)
        for door: Any in ["", false, 0, "web-1", ["a"]] {
            let request = found(AnswerSecretSample.item(secret: ["env": "EXAMPLE_API_KEY", "door": door]))
            #expect(request?.door == true, "\(door)")
        }
        for kind: Any in [7, true, NSNull(), ["login"], "api_key", "Login", ""] {
            let request = found(AnswerSecretSample.item(secret: ["kind": kind, "env": "EXAMPLE_API_KEY"]))
            #expect(request == AnswerSecretSample.asksKey, "\(kind)")
        }
        #expect(found(AnswerSecretSample.item(secret: ["kind": "login"]))?.apiKey == false)
    }

    /// **For the rows that the hub writes, the tool's fit is the form's.** The same JSON `secret` is decoded by
    /// FleetCore's `NeedSecret`, as the app's form reads it, and by the tool's own read; then both say, for each
    /// secret of a list, whether it fits. The rows have the hub's real shape: an API key with its variable name, a
    /// login with an `https://` site with a path, a login with a site whose host has upper case letters, and a
    /// request for a login with no site.
    @Test func theFitOfTheHubsRowsIsTheFormsOwn() throws {
        let rows: [[String: Any]] = [
            ["kind": "api_key", "env": "EXAMPLE_API_KEY", "give": ["nova": "read"], "tasks": [7]],
            ["kind": "login", "site": "https://dashboard.example.com/login?next=home", "give": ["nova": "use"]],
            ["kind": "login", "site": "https://Dashboard.Example.COM", "give": [String: String]()],
            ["kind": "login"],
            ["env": "EXAMPLE_API_KEY"],
        ]
        let entries = [
            TeamLogin(title: "EXAMPLE_API_KEY", protected: nil, kind: "api_key", env: "EXAMPLE_API_KEY"),
            TeamLogin(title: "Another title", protected: nil, kind: "api_key", env: "EXAMPLE_API_KEY"),
            TeamLogin(title: "EXAMPLE_API_KEY", protected: nil, kind: "api_key", env: "OTHER_API_KEY"),
            TeamLogin(title: "EXAMPLE_API_KEY", protected: nil, kind: "api_key"),
            TeamLogin(title: "a · b", protected: nil, kind: "api_key", env: "A_B"),
            TeamLogin(title: "dashboard.example.com · ops@example.com", protected: nil, kind: "login"),
            TeamLogin(title: "Dashboard.Example.com · ops@example.com", protected: nil, kind: "login"),
            TeamLogin(title: "mail.example.com · ops@example.com", protected: nil, kind: "login"),
            TeamLogin(title: "dashboard.example.com.other.example · ops", protected: nil, kind: "login"),
            TeamLogin(title: "dashboard.example.com", protected: nil, kind: "login"),
            TeamLogin(title: "No dot at all", protected: nil, kind: "login"),
            TeamLogin(title: "EXAMPLE_API_KEY", protected: nil, kind: "login"),
        ]
        var fitting = 0
        for row in rows {
            let json = try JSONSerialization.data(withJSONObject: row)
            let form = try JSONDecoder().decode(NeedSecret.self, from: json)
            let tool = try #require(found(AnswerSecretSample.item(secret: row)))
            #expect(tool.apiKey == (form.kind == .apiKey) && tool.env == form.env && tool.site == form.site)
            for entry in entries {
                let kind: LoginSecret.Kind = entry.isAPIKey ? .apiKey : .login
                let secret = GrantSecret.Team.Secret(apiKey: entry.isAPIKey, env: entry.env, title: entry.title)
                // The form lists a secret of the request's kind whose shown name fits (`SecretEntryView`), and the
                // hub refuses another kind (`answer_secret`).
                let wanted = kind == form.kind && form.fits(title: entry.name)
                #expect(tool.fits(secret) == wanted, "\(row): \(entry.title)")
                if wanted { fitting += 1 }
            }
        }
        // Not a comparison of two rules that both say no: some secrets fit, for a key and for a login.
        #expect(fitting >= 8)
    }

    /// **A site is only a text that starts with `https://` and gives a host**; any other one is no site.
    @Test func aBadSiteIsNoSite() {
        func site(_ value: Any) -> String? {
            found(AnswerSecretSample.item(secret: ["kind": "login", "site": value]))?.site
        }
        #expect(site("https://dashboard.example.com/login") == "https://dashboard.example.com/login")
        #expect(site("https://Dashboard.Example.com") == "https://Dashboard.Example.com")
        for bad: Any in ["http://dashboard.example.com", "dashboard.example.com", "https://", "https:///login", "",
                         "ftp://example.com", 7, NSNull(), ["https://example.com"]] {
            #expect(site(bad) == nil, "\(bad)")
        }
    }

    /// **A secret request with no `secret`, or with one that is no object**, is a request for an API key of no
    /// name: found, and nothing fits it.
    @Test func aMissingSecretAsksForAKeyOfNoName() {
        for secret: Any? in [nil, NSNull(), "text", [1, 2]] {
            let request = found(AnswerSecretSample.item(secret: secret))
            #expect(request == .init())
            #expect(AnswerSecretSample.list().secrets.values.allSatisfy { request?.fits($0) == false })
        }
    }

    /// **The rule of a secret that fits**: the same kind; a key by its name (its variable name, else its title);
    /// a login by the request's host in lower case and " · "; a request with no site by a title that holds " · ".
    @Test func theFitRule() {
        typealias Secret = GrantSecret.Team.Secret
        let asksKey = AnswerSecretSample.asksKey
        #expect(asksKey.fits(Secret(apiKey: true, env: "EXAMPLE_API_KEY")))
        #expect(asksKey.fits(Secret(apiKey: true, env: "EXAMPLE_API_KEY", title: "Another title")))
        #expect(asksKey.fits(Secret(apiKey: true, title: "EXAMPLE_API_KEY")))
        #expect(!asksKey.fits(Secret(apiKey: true, env: "OTHER_API_KEY", title: "EXAMPLE_API_KEY")))
        #expect(!asksKey.fits(Secret(apiKey: true, env: "example_api_key")))
        #expect(!asksKey.fits(Secret(apiKey: true)))
        #expect(!asksKey.fits(Secret(apiKey: false, env: "EXAMPLE_API_KEY", title: "EXAMPLE_API_KEY")))
        #expect(!AnswerSecret.Request(env: nil).fits(Secret(apiKey: true, env: "EXAMPLE_API_KEY")))

        let asksLogin = AnswerSecret.Request(apiKey: false, site: "https://Dashboard.Example.com/login")
        #expect(asksLogin.host == "dashboard.example.com")
        #expect(asksLogin.fits(Secret(apiKey: false, title: "dashboard.example.com · ops@example.com")))
        #expect(!asksLogin.fits(Secret(apiKey: false, title: "mail.example.com · ops@example.com")))
        #expect(!asksLogin.fits(Secret(apiKey: false, title: "dashboard.example.com.evil.example · ops")))
        #expect(!asksLogin.fits(Secret(apiKey: false, title: "dashboard.example.com")))
        #expect(!asksLogin.fits(Secret(apiKey: false)))
        #expect(!asksLogin.fits(Secret(apiKey: true, env: "EXAMPLE_API_KEY",
                                       title: "dashboard.example.com · ops@example.com")))
        let anyLogin = AnswerSecret.Request(apiKey: false)
        #expect(anyLogin.fits(Secret(apiKey: false, title: "mail.example.com · ops@example.com")))
        #expect(!anyLogin.fits(Secret(apiKey: false, title: "A title with no dot")))
        #expect(!anyLogin.fits(Secret(apiKey: true, env: "EXAMPLE_API_KEY", title: "a · b")))
    }

    /// The rule is FleetCore's own (`NeedSecret.fits(title:)` over the entry's shown name), for a key and a login.
    @Test func theFitRuleIsTheFormsOwn() {
        let entries = [TeamLogin(title: "EXAMPLE_API_KEY", protected: nil, kind: "api_key", env: "EXAMPLE_API_KEY"),
                       TeamLogin(title: "A key", protected: nil, kind: "api_key", env: "OTHER_API_KEY"),
                       TeamLogin(title: "EXAMPLE_API_KEY", protected: nil, kind: "api_key"),
                       TeamLogin(title: "dashboard.example.com · ops@example.com", protected: nil, kind: "login"),
                       TeamLogin(title: "mail.example.com · ops@example.com", protected: nil, kind: "login"),
                       TeamLogin(title: "No dot", protected: nil, kind: "login")]
        let asks: [(NeedSecret, AnswerSecret.Request)] = [
            (NeedSecret(kind: .apiKey, env: "EXAMPLE_API_KEY"), AnswerSecretSample.asksKey),
            (NeedSecret(kind: .login, site: AnswerSecretSample.site), AnswerSecretSample.asksLogin),
            (NeedSecret(kind: .login), AnswerSecret.Request(apiKey: false)),
        ]
        for (form, tool) in asks {
            for entry in entries {
                let kind: LoginSecret.Kind = entry.isAPIKey ? .apiKey : .login
                let secret = GrantSecret.Team.Secret(apiKey: entry.isAPIKey, env: entry.env, title: entry.title)
                #expect(tool.fits(secret) == (kind == form.kind && form.fits(title: entry.name)), "\(entry.title)")
            }
        }
    }
}

// ------------------------------------------------------------ the app's answer

/// **The app's answer to one call**, with a stand-in desk.
@MainActor
struct OwnerAnswerSecretAppTests {
    let one = AnswerSecretSample.one
    let none = AnswerSecretSample.none
    let three = AnswerSecretSample.three
    let checks = AnswerSecretSample.checks
    let key = AnswerSecretSample.key

    private func comes(_ done: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    // ------------------------------------------------------------ the calls that go

    /// **One give and the answer**: the checks, the signed grant for the agent's server, the hub's grant, the
    /// answer of the request, and the app's refresh. The result has the fields of the tool, and nothing else.
    @Test func aCallGivesFirstAndAnswersSecond() async throws {
        let app = StandInAnswerDesk()
        app.receipt = .init(changed: true, access: .init(before: "none", after: "broker", missing: []))
        let answer = try await app.went(one)
        #expect(app.asked == checks + ["sign grant nova w5", "grant nova use", "answer", "refresh"])
        #expect(app.statements == [.init(fleet: AnswerSecretSample.fleet, login: key, agent: "nova", machine: "w5")])
        #expect(app.grants == ["\(key) nova use"] && app.answers == ["12 \(key)"] && app.needsRead == [12])
        #expect(app.refreshes == 1 && !app.line.busy)
        #expect(answer == [
            "need": .int(12), "login": .string(key), "answered": .bool(true),
            "given": .array([.object([
                "agent": .string("nova"), "level": .string("use"), "server": .string("w5"), "changed": .bool(true),
                "vault": .object(["before": .string("none"), "after": .string("broker"), "missing": .array([])]),
                "note": .string(GrantSecret.note(.use, app.receipt)),
            ])]),
            "note": .string(AnswerSecret.noteAnswered),
        ])
    }

    /// **The gives go in the byte order of the names**, each signed first and written second, and the answer goes
    /// last. `given` has them in that order, each with its own level and server.
    @Test func theGivesGoInNameOrderAndTheAnswerLast() async throws {
        let app = StandInAnswerDesk()
        let answer = try await app.went(three)
        #expect(app.asked == checks + ["sign grant atlas w6", "grant atlas use", "sign grant nova w5",
                                       "grant nova read", "sign grant orion w7", "grant orion use", "answer",
                                       "refresh"])
        let given = try #require(answer["given"]?.array)
        #expect(given.map { $0["agent"] } == [.string("atlas"), .string("nova"), .string("orion")])
        #expect(given.map { $0["level"] } == [.string("use"), .string("read"), .string("use")])
        #expect(given.map { $0["server"] } == [.string("w6"), .string("w5"), .string("w7")])
        #expect(given.allSatisfy { $0["vault"] == nil && $0["login"] == nil && $0["signed"] == nil })
        #expect(given[1]["note"] == .string(GrantSecret.note(.read, app.receipt)))
        #expect(answer["answered"] == .bool(true) && answer["note"] == .string(AnswerSecret.noteAnswered))
        #expect(app.ungrants == 0 && app.answers.count == 1)
    }

    /// **A call with `give` `{}` reads no vault, asks for no key and signs nothing**: its one write is the answer.
    /// It goes also on a hub that takes no signed grant, on a Mac with no owner key and with no vault's page, and it
    /// never asks for the clocks.
    @Test func aCallWithNoGiveOnlyAnswers() async throws {
        let app = StandInAnswerDesk()
        app.signs = false
        app.vault = nil
        app.holdsKey = false
        let answer = try await app.went(none)
        #expect(!app.clockAsked)
        #expect(app.asked == AnswerSecretSample.checksOfNoGive + ["answer", "refresh"])
        #expect(app.statements.isEmpty && app.grants.isEmpty && app.answers == ["12 \(key)"])
        #expect(answer == ["need": .int(12), "login": .string(key), "answered": .bool(true), "given": .array([]),
                           "note": .string("\(AnswerSecret.noteAnswered) \(AnswerSecret.noteNoGive)")])
    }

    /// A login answers a request for a login of its site, to a lead at `use`. No free text of the hub is in a
    /// result: a vault word that is no code is a null.
    @Test func aLoginAnswersARequestForALoginOfItsSite() async throws {
        let app = StandInAnswerDesk()
        app.requests = [.found(AnswerSecretSample.asksLogin)]
        app.receipt = .init(changed: false, access: .init(before: "Not A Code", after: "none", missing: ["no_vault",
                                                                                                         "Free text"]))
        let answer = try await app.went(AnswerSecretSample.call(AnswerSecretSample.password, give: ["lead-1": "use"]))
        #expect(app.grants == ["\(AnswerSecretSample.password) lead-1 use"])
        let entry = try #require(answer["given"]?.array?.first)
        #expect(entry["changed"] == .bool(false) && entry["server"] == .string("w8"))
        #expect(entry["vault"] == .object(["before": .null, "after": .string("none"),
                                           "missing": .array([.string("no_vault")])]))
    }

    // ------------------------------------------------------------ each step, in its order

    /// One refusal before the first write: what the desk was asked up to it, and that no write was called.
    private func refused(_ fields: [String: JSONValue], _ words: String, asked: [String],
                         value: OwnerChannel.Value? = nil, _ change: (StandInAnswerDesk) -> Void = { _ in }) async {
        let app = StandInAnswerDesk()
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
        await refused(AnswerSecretSample.with(["need": .string("12")]), AnswerSecret.needWord, asked: [])
        await refused(AnswerSecretSample.with(["login": .string("secret:" + key)]), AnswerSecret.loginWord, asked: [])
        await refused(one.filter { $0.key != "give" }, AnswerSecret.needsGive, asked: [])
        await refused(AnswerSecretSample.with(["give": .array([])]), AnswerSecret.giveWord, asked: [])
        await refused(AnswerSecretSample.call(give: ["Nova": "use"]), AnswerSecret.giveAgentWord, asked: [])
        await refused(AnswerSecretSample.call(give: ["nova": "all"]), AnswerSecret.giveLevelWord, asked: [])
        await refused(AnswerSecretSample.with(["more": .int(1)]), AnswerSecret.only, asked: [])
        await refused(AnswerSecretSample.with(["token": .string("x")]), OwnerLinkTools.neverAField, asked: [])
        await refused(one, AnswerSecret.noPart, asked: [], value: OwnerChannel.Value(copying: Array("more".utf8)))
    }

    /// **Steps 2 to 4, each with its own sentence, in their order.** Each case fails one check; the desk is asked
    /// up to that check, with no read that the step does not need, and no write is called.
    @Test func eachCheckRefusesInItsOrderAndSendsNothing() async {
        let short = AnswerSecretSample.checksOfNoGive
        // 2. A current reading.
        await refused(one, AnswerSecret.notReady, asked: ["ready"]) { $0.ready = false }
        await refused(none, AnswerSecret.notReady, asked: ["ready"]) { $0.ready = false }
        // 3. Signed grants, only for a call with a give.
        await refused(one, AnswerSecret.notReady, asked: ["ready", "signs"]) { $0.signs = nil }
        await refused(one, AnswerSecret.noSignedGrants, asked: ["ready", "signs"]) { $0.signs = false }
        // 4. The reads: the request, the list, and the vault's page only for a call with a give.
        await refused(one, AnswerSecret.requestUnread, asked: ["ready", "signs", "request"]) { $0.requests = [nil] }
        await refused(none, AnswerSecret.requestUnread, asked: ["ready", "request"]) { $0.requests = [nil] }
        await refused(one, AnswerSecret.teamUnread, asked: ["ready", "signs", "request", "team"]) { $0.teams = [nil] }
        await refused(none, AnswerSecret.teamUnread, asked: short) { $0.teams = [nil] }
        let reads = ["ready", "signs", "request", "team", "vault"]
        await refused(one, AnswerSecret.vaultUnread, asked: reads) { $0.vault = nil }
        // The request, for a call with a give (after its three reads) and for one with none.
        for (fields, asked) in [(one, reads), (none, short)] {
            await refused(fields, AnswerSecret.requestUnread, asked: asked) { $0.requests = [.unreadable] }
            await refused(fields, AnswerSecret.notReady, asked: asked) { $0.requests = [.otherGeneration] }
            await refused(fields, AnswerSecret.noRequest, asked: asked) { $0.requests = [AnswerSecret.RequestRead.none] }
            await refused(fields, AnswerSecret.notSecretRequest, asked: asked) {
                $0.requests = [.found(.init(isSecret: false))]
            }
            await refused(fields, AnswerSecret.answeredWithThis, asked: asked) {
                $0.requests = [.found(.init(open: false, env: AnswerSecretSample.variable, saved: key))]
            }
            await refused(fields, AnswerSecret.answeredAlready, asked: asked) {
                $0.requests = [.found(.init(open: false, env: AnswerSecretSample.variable,
                                            saved: AnswerSecretSample.twin))]
            }
            await refused(fields, AnswerSecret.answeredAlready, asked: asked) {
                $0.requests = [.found(.init(open: false, env: AnswerSecretSample.variable))]
            }
            await refused(fields, AnswerSecret.doorNeedsDoor, asked: asked) {
                $0.requests = [.found(.init(env: AnswerSecretSample.variable, door: true))]
            }
        }
        // A request for the door: the door at read; an agent beside the door for a key of the door, which the door
        // alone holds; and a request that the door got with an answer of this secret already.
        await refused(AnswerSecretSample.call(give: ["door": "read"]), AnswerSecret.doorUsesOnly, asked: reads) {
            $0.requests = [.found(.init(env: AnswerSecretSample.variable, door: true))]
        }
        await refused(AnswerSecretSample.call(give: ["door": "use", "nova": "use"]), AnswerSecret.doorKeyAlone,
                      asked: reads) { $0.requests = [.found(.init(env: AnswerSecretSample.variable, doorKey: true))] }
        await refused(AnswerSecretSample.call(give: ["door": "use"]), AnswerSecret.answeredWithThisForDoor,
                      asked: reads) {
            $0.requests = [.found(.init(open: false, env: AnswerSecretSample.variable, doorKey: true, saved: key))]
        }
        // A request whose proposal only names the door claims no hold of the door: the app's form answers it also
        // after a give to the door that failed.
        await refused(AnswerSecretSample.call(give: ["door": "use"]), AnswerSecret.answeredWithThis, asked: reads) {
            $0.requests = [.found(.init(open: false, env: AnswerSecretSample.variable, door: true, saved: key))]
        }
        // The secret: the list has it, and it fits.
        await refused(AnswerSecretSample.call(AnswerSecretSample.unknown), AnswerSecret.noSecret, asked: reads)
        await refused(AnswerSecretSample.call(AnswerSecretSample.unknown, give: [:]), AnswerSecret.noSecret,
                      asked: short)
        for login in [AnswerSecretSample.otherKey, AnswerSecretSample.password] {
            await refused(AnswerSecretSample.call(login), AnswerSecret.notFitting, asked: reads)
            await refused(AnswerSecretSample.call(login, give: [:]), AnswerSecret.notFitting, asked: short)
        }
        for login in [key, AnswerSecretSample.otherPassword] {
            await refused(AnswerSecretSample.call(login, give: [:]), AnswerSecret.notFitting, asked: short) {
                $0.requests = [.found(AnswerSecretSample.asksLogin)]
            }
        }
        // The vault's page and the owner key, only for a call with a give.
        await refused(one, AnswerSecret.noFleet, asked: reads) { $0.vault = .init(fleet: nil, central: .answers) }
        await refused(one, AnswerSecret.noVaultReading, asked: reads) {
            $0.vault = .init(fleet: AnswerSecretSample.fleet, central: .noReading)
        }
        await refused(one, AnswerSecret.vaultSilent, asked: reads) {
            $0.vault = .init(fleet: AnswerSecretSample.fleet, central: .silent)
        }
        await refused(one, AnswerSecret.noOwnerKey, asked: checks) { $0.holdsKey = false }
        // Last, only for a call with a give: this Mac's clock and the hub's differ by more than an hour; and with no
        // answer of the hub in this launch, the call is not ready (it fails closed).
        await refused(one, AnswerSecret.clockApart, asked: checks) { $0.clockApart = true }
        await refused(one, AnswerSecret.notReady, asked: checks) { $0.clockApart = nil }
    }

    /// **The checks of each agent of `give`, in the byte order of the names**: the first agent that fails names
    /// the refusal, with its own name, and nothing is sent for any agent.
    @Test func eachAgentIsCheckedInNameOrder() async {
        func give(_ give: [String: String], _ login: String = AnswerSecretSample.key) -> [String: JSONValue] {
            AnswerSecretSample.call(login, give: give)
        }
        await refused(give(["nova": "use", "ghost": "use"]), AnswerSecret.noAgent("ghost"), asked: checks)
        // The door's name has an agent's form, and it is a holder only for a request for the door: in any other
        // request it is refused with the request's checks, before the key, also when an agent has that name.
        let reads = ["ready", "signs", "request", "team", "vault"]
        await refused(give(["door": "use"]), AnswerSecret.doorNotAsked, asked: reads)
        await refused(give(["door": "use", "nova": "use"]), AnswerSecret.doorNotAsked, asked: reads) { app in
            var agents = AnswerSecretSample.list().agents
            agents["door"] = .init(role: "worker", machine: "w5")
            app.teams = [.init(secrets: AnswerSecretSample.list().secrets, agents: agents)]
        }
        await refused(give(["nova": "use", "manager": "use"]), AnswerSecret.notWorker("manager"), asked: checks)
        for machine: String? in [nil, "", "W 5"] {
            await refused(give(["atlas": "use", "nova": "use"]), AnswerSecret.noServer("nova"), asked: checks) { app in
                var agents = AnswerSecretSample.list().agents
                agents["nova"] = .init(role: "worker", machine: machine)
                app.teams = [.init(secrets: AnswerSecretSample.list().secrets, agents: agents)]
            }
        }
        await refused(give(["nova": "read"], AnswerSecretSample.password), AnswerSecret.readNeedsKey("nova"),
                      asked: checks) { $0.requests = [.found(AnswerSecretSample.asksLogin)] }
        await refused(give(["atlas": "use", "nova": "read"]), AnswerSecret.readsTwice("nova"), asked: checks) {
            $0.teams = [AnswerSecretSample.list(twin: ["nova": "read"])]
        }
        // Two agents fail: the first one in the byte order names the refusal.
        await refused(give(["zed": "use", "ghost": "use", "manager": "use"]), AnswerSecret.noAgent("ghost"),
                      asked: checks)
        await refused(give(["manager": "use", "zed": "use"]), AnswerSecret.notWorker("manager"), asked: checks)
        // The clocks come after the checks of every agent, also of the last one in the byte order.
        await refused(give(["atlas": "use", "nova": "read"]), AnswerSecret.readsTwice("nova"), asked: checks) {
            $0.teams = [AnswerSecretSample.list(twin: ["nova": "read"])]; $0.clockApart = true
        }
        // An agent that uses the twin key, and one that reads this key already, are no "reads twice".
        let app = StandInAnswerDesk()
        app.teams = [AnswerSecretSample.list(grants: ["nova": "read"], twin: ["nova": "use"])]
        #expect(await app.refusal(give(["nova": "read"])) == nil)
    }

    // ------------------------------------------------------------ a request for the door

    /// **A request for the door is answered as the app's form answers it** (the owner's agent does each step that
    /// needs nothing from the owner): the door gets the secret with a grant signed for the door's own name, in the
    /// byte order of the names beside the agents that the owner named, and then the request gets its answer. The
    /// door is no agent of the team, so no check of an agent is asked of it, and its entry in `given` has no server.
    @Test func aRequestForTheDoorGivesItToTheDoorAndThenAnswers() async throws {
        let forDoor = AnswerSecret.RequestRead.found(.init(env: AnswerSecretSample.variable, door: true))
        let app = StandInAnswerDesk()
        app.requests = [forDoor]
        let answer = try await app.went(AnswerSecretSample.call(give: ["nova": "use", "door": "use"]))
        #expect(app.asked == checks + ["sign grant door door", "grant door use", "sign grant nova w5",
                                       "grant nova use", "answer", "refresh"])
        #expect(app.statements.first == .init(fleet: AnswerSecretSample.fleet, login: key, agent: "door",
                                              machine: "door"))
        let given = try #require(answer["given"]?.array)
        #expect(given.first == .object(["agent": .string("door"), "level": .string("use"), "changed": .bool(true),
                                        "note": .string(AnswerSecret.noteDoor)]))
        #expect(given.last?["agent"] == .string("nova") && given.last?["server"] == .string("w5"))
        // A key of the door goes to the door alone. The door held it already: no change in the list, and its own
        // note.
        let held = StandInAnswerDesk()
        held.requests = [.found(.init(env: AnswerSecretSample.variable, doorKey: true))]
        held.receipt = .init(changed: false)
        let alone = try await held.went(AnswerSecretSample.call(give: ["door": "use"]))
        #expect(alone["given"] == .array([.object(["agent": .string("door"), "level": .string("use"),
                                                   "changed": .bool(false),
                                                   "note": .string(AnswerSecret.noteDoorSame)])]))
        #expect(held.answers == ["12 \(key)"])
    }

    /// **A grant of the door that the hub refuses is taken back with no read of the list**: the hub refuses the
    /// door's grant only when the door does not hold the secret after it, and the team's page never shows the
    /// door's hold, so the app signs the end at once. The words name the door, not "the agent door", and never send
    /// the caller to `grant_secret`, which takes no grant of the door.
    @Test func aRefusedGrantOfTheDoorIsTakenBackWithNoRead() async {
        let app = StandInAnswerDesk()
        app.requests = [.found(.init(env: AnswerSecretSample.variable, door: true))]
        app.grantAnswers = [SaveBotToken.HubFailure.refused(409, "this fleet has no door")]
        let words = await app.refusal(AnswerSecretSample.call(give: ["door": "use"]))
        #expect(app.asked == checks + ["sign grant door door", "grant door use", "sign ungrant door"])
        #expect(words == AnswerSecret.stopped(.refusedTakenBack(409, "this fleet has no door"), agent: "door",
                                              before: []))
        #expect(app.answers.isEmpty && app.ungrants == 1)
        // The end that did not go: a signed grant stays, and the owner is told.
        let left = StandInAnswerDesk()
        left.requests = app.requests
        left.grantAnswers = app.grantAnswers
        left.signAnswers = [nil, SaveBotToken.HubFailure.refused(400, "no")]
        #expect(await left.refusal(AnswerSecretSample.call(give: ["door": "use"]))
                == AnswerSecret.stopped(.refusedSignatureLeft(409, "this fleet has no door"), agent: "door",
                                        before: []))
        for end in AnswerSecretSample.stops {
            let said = AnswerSecret.stopped(end, agent: "door", before: ["atlas"])
            #expect(said.contains("the door") && !said.contains("the agent door") && !said.contains("grant_secret"),
                    "\(said)")
            #expect(said.contains("gave the secret to: atlas.") && said.contains(AnswerSecret.noAnswerYet), "\(said)")
        }
        #expect(AnswerSecret.stopped(.refusedSignatureLeft(409, "no"), agent: "door", before: [])
            .contains("The door gets a copy only of a secret that its own list names. Tell the owner."))
    }

    // ------------------------------------------------------------ one line of writes for two tools

    /// **A call of `grant_secret` is refused while this tool writes, and the other way round**: the two tools share
    /// one line. The refused call ran its own checks and sent nothing.
    @Test func theLineIsSharedWithGrantSecret() async throws {
        let line = GrantSecret.Line()
        let app = StandInAnswerDesk(line: line)
        let grants = StandInGrantDesk()
        let give = GrantSecretSample.give
        func grant() async -> OwnerChannel.Answer {
            await GrantSecret.answer(fields: give, value: nil, desk: grants.desk, line: line)
        }
        // This tool's first write waits: a call of grant_secret gets `busy`, and a second call of this tool too.
        app.holdAt = ["sign"]
        let first = app.call(one)
        #expect(await comes { app.holds("sign") == 1 })
        #expect(line.busy)
        #expect(await grant() == .refused(GrantSecret.busy))
        #expect(grants.asked == GrantSecretSample.checks && grants.writes == 0)
        #expect(await app.answer(none) == .refused(AnswerSecret.busy))
        #expect(app.answers.isEmpty && app.statements.count == 1)
        app.holdAt = []
        app.open("sign")
        guard case .result = await first.value else {
            Issue.record("the first call did not end with a result")
            return
        }
        #expect(!line.busy)
        // The other way round: grant_secret's first write waits, and this tool gets `busy`, with a give and with none.
        grants.holdAt = ["sign"]
        let second = Task { @MainActor in await grant() }
        #expect(await comes { grants.holds("sign") == 1 })
        #expect(line.busy)
        let before = app.writes
        for fields in [one, none] {
            #expect(await app.answer(fields) == .refused(AnswerSecret.busy))
        }
        #expect(app.writes == before)
        grants.holdAt = []
        grants.open("sign")
        guard case .result = await second.value else {
            Issue.record("the call of grant_secret did not end with a result")
            return
        }
        // The line is free: the next call of this tool writes. Its request is open in the stand-in still.
        #expect(!line.busy)
        #expect(await app.refusal(none) == nil)
    }

    /// **A caller that went away before the first write sends nothing.** The call's task is cancelled during one
    /// of its reads: the checks pass, and no write is called.
    @Test func aCallerThatWentAwayBeforeTheFirstWriteSendsNothing() async {
        for (fields, places, asked) in [(one, ["request", "team", "vault"], checks),
                                        (none, ["request", "team"], AnswerSecretSample.checksOfNoGive)] {
            for place in places {
                let app = StandInAnswerDesk()
                app.cancelAt = place
                let answer = await app.call(fields).value
                #expect(answer == .refused(AnswerSecret.ended), "\(place)")
                #expect(app.asked == asked && app.writes == 0 && app.refreshes == 0 && !app.line.busy, "\(place)")
            }
        }
    }

    /// **From its first write on, a call goes to its end also when its caller went away.** The first write waits;
    /// the caller's task is cancelled; each later write still runs, one time, and none saw a cancel.
    @Test func aCallerThatWentAwayAfterTheFirstWriteStillGetsEachLaterWrite() async throws {
        let app = StandInAnswerDesk()
        app.holdAt = ["sign"]
        let call = app.call(three)
        #expect(await comes { app.holds("sign") == 1 })
        call.cancel()
        for _ in 0..<5 { await Task.yield() }
        #expect(app.holds("sign") == 1 && app.line.busy && call.isCancelled && app.statements.count == 1)
        app.holdAt = []
        app.open("sign")
        guard case .result(let answer) = await call.value else {
            Issue.record("the call did not end with a result")
            return
        }
        #expect(answer["answered"] == .bool(true) && answer["given"]?.array?.count == 3)
        #expect(app.statements.count == 3 && app.grants.count == 3 && app.answers.count == 1 && !app.line.busy)
        let writes = app.steps.filter { ["sign", "grant", "answer"].contains($0.name) }
        #expect(writes.map(\.name) == ["sign", "grant", "sign", "grant", "sign", "grant", "answer"])
        #expect(writes.allSatisfy { !$0.cancelled }, "\(writes)")

        // A call with no give: the answer waits, the caller goes, and the call still ends with its result.
        let other = StandInAnswerDesk()
        other.holdAt = ["answer"]
        let second = other.call(none)
        #expect(await comes { other.holds("answer") == 1 })
        second.cancel()
        other.open("answer")
        guard case .result = await second.value else {
            Issue.record("the call with no give did not end with a result")
            return
        }
        #expect(other.steps.filter { $0.name == "answer" }.allSatisfy { !$0.cancelled })
    }

    // ------------------------------------------------------------ a give that stops the call

    /// **The first give that does not end in a grant stops the call**, for each end of a give: no later give, no
    /// answer, and words that name the agent, the agents that got the secret before it, and that the call did not
    /// answer the request. Here atlas gets the secret, nova's give fails, and orion's is never tried.
    @Test func theFirstGiveThatFailsStopsTheCall() async {
        let lost = SaveBotToken.HubFailure.noAnswer
        let no = SaveBotToken.HubFailure.refused(409, "no")
        let list = AnswerSecretSample.list()
        struct Case {
            let end: GrantSecret.GiveEnd
            var signs: [(any Error)?] = [nil]
            var grants: [(any Error)?] = [nil]
            var teams: [GrantSecret.Team?] = [AnswerSecretSample.list()]
            let last: [String]
        }
        let cases = [
            Case(end: .notSignedNow, signs: [nil, GrantSecret.NotSigned()], last: ["sign grant nova w5"]),
            Case(end: .signRefused(400, "older"), signs: [nil, SaveBotToken.HubFailure.refused(400, "older")],
                 last: ["sign grant nova w5"]),
            Case(end: .signNotKnown, signs: [nil, lost], last: ["sign grant nova w5"]),
            Case(end: .grantNotKnown, grants: [nil, lost], last: ["sign grant nova w5", "grant nova read"]),
            Case(end: .refusedTakenBack(409, "no"), grants: [nil, no],
                 last: ["sign grant nova w5", "grant nova read", "team", "sign ungrant nova"]),
            Case(end: .refusedSignatureLeft(409, "no"), signs: [nil, nil, lost], grants: [nil, no],
                 last: ["sign grant nova w5", "grant nova read", "team", "sign ungrant nova"]),
            Case(end: .refusedListHasOne(409, "no"), grants: [nil, no],
                 teams: [list, AnswerSecretSample.list(grants: ["nova": "use"])],
                 last: ["sign grant nova w5", "grant nova read", "team"]),
            Case(end: .refusedListUnread(409, "no"), grants: [nil, no], teams: [list, nil],
                 last: ["sign grant nova w5", "grant nova read", "team"]),
        ]
        #expect(cases.map(\.end) == AnswerSecretSample.stops)
        for one in cases {
            let app = StandInAnswerDesk()
            app.signAnswers = one.signs
            app.grantAnswers = one.grants
            app.teams = one.teams
            let words = await app.refusal(three)
            #expect(words == AnswerSecret.stopped(one.end, agent: "nova", before: ["atlas"]), "\(one.end)")
            // Atlas's give went; nova's stopped the call; the list changed, so the app reads the fleet again.
            #expect(app.asked == checks + ["sign grant atlas w6", "grant atlas use"] + one.last + ["refresh"],
                    "\(one.end)")
            #expect(app.answers.isEmpty && !app.line.busy, "\(one.end)")
            #expect(!app.asked.contains { $0.contains("orion") }, "\(one.end)")
            #expect(words?.contains("orion") == false && words?.contains(key) == false, "\(one.end)")
            #expect(words?.contains("Nothing was sent") == false, "\(one.end)")
        }
        // The first give itself fails: no agent got the secret, and the app reads nothing again.
        let app = StandInAnswerDesk()
        app.signAnswers = [lost]
        let words = await app.refusal(three)
        #expect(words == AnswerSecret.stopped(.signNotKnown, agent: "atlas", before: []))
        #expect(app.asked == checks + ["sign grant atlas w6"] && app.answers.isEmpty && app.refreshes == 0)
        #expect(words?.contains("Before that, this call gave the secret to no agent.") == true)
    }

    /// **The signed `ungrant` goes only in its one case**: the hub refused the grant, and the list read again has
    /// no grant of this secret for this agent. This tool never ends a grant in the list.
    @Test func noGiveIsTakenBackButARefusedOne() async {
        let app = StandInAnswerDesk()
        app.grantAnswers = [SaveBotToken.HubFailure.refused(409, "no")]
        _ = await app.refusal(one)
        #expect(app.ungrants == 1 && app.statements.last?.agent == "nova" && app.grants == ["\(key) nova use"])
        for answers: [(any Error)?] in [[AnswerSecret.Answered()], [SaveBotToken.HubFailure.refused(404, "gone")],
                                        [SaveBotToken.HubFailure.noAnswer]] {
            let other = StandInAnswerDesk()
            other.answerAnswers = answers
            _ = await other.refusal(three)
            #expect(other.ungrants == 0 && other.statements.count == 3 && other.grants.count == 3)
        }
    }

    // ------------------------------------------------------------ the answer's own outcomes

    /// **The hub says that the request had its answer**: the app reads the request one time more, and says what
    /// that read shows. This secret: an answer before this one. A decline or another secret: the request was closed
    /// came first. A read that failed, or that shows no answer: not read. The gives stand, named, and none is
    /// taken back.
    @Test func aRequestThatHadItsAnswerIsReadOneTimeMore() async {
        let open = AnswerSecret.RequestRead.found(AnswerSecretSample.asksKey)
        func answered(saved: String?) -> AnswerSecret.RequestRead {
            .found(.init(open: false, env: AnswerSecretSample.variable, saved: saved))
        }
        let cases: [(AnswerSecret.RequestRead?, ([String]) -> String)] = [
            (answered(saved: key), AnswerSecret.hadAnswerWithThis),
            (answered(saved: AnswerSecretSample.twin), AnswerSecret.closedFirst),
            (answered(saved: nil), AnswerSecret.closedFirst),
            (nil, AnswerSecret.answeredUnread), (open, AnswerSecret.answeredUnread),
            (AnswerSecret.RequestRead.none, AnswerSecret.answeredUnread),
            (.otherGeneration, AnswerSecret.answeredUnread), (.unreadable, AnswerSecret.answeredUnread),
        ]
        for (again, words) in cases {
            let app = StandInAnswerDesk()
            app.requests = [open, again]
            app.answerAnswers = [AnswerSecret.Answered()]
            #expect(await app.refusal(three) == words(["atlas", "nova", "orion"]), "\(String(describing: again))")
            #expect(Array(app.asked.suffix(3)) == ["answer", "request", "refresh"])
            #expect(app.needsRead == [12, 12] && app.answers.count == 1 && app.ungrants == 0 && !app.line.busy)
            // With no give, nothing changed: no refresh.
            let bare = StandInAnswerDesk()
            bare.requests = [open, again]
            bare.answerAnswers = [AnswerSecret.Answered()]
            #expect(await bare.refusal(none) == words([]))
            #expect(bare.asked == AnswerSecretSample.checksOfNoGive + ["answer", "request"])
        }
    }

    /// **Every other certain refusal of the answer** has the hub's words after the tool's sentence, and the gives
    /// stand, named. **An outcome that is not known** says so, and the same call again is the next step.
    @Test func theAnswerRefusedAndTheAnswerNotKnown() async {
        for (status, said) in [(404, "This request is not known, or it ended."), (409, "this owner request asks for "
                                                                                  + "no secret"), (400, "")] {
            let app = StandInAnswerDesk()
            app.answerAnswers = [SaveBotToken.HubFailure.refused(status, said)]
            let words = await app.refusal(one)
            #expect(words == GrantSecret.withHubWords(AnswerSecret.answerRefused(["nova"]), status: status, said))
            #expect(words?.hasPrefix("The hub refused the answer, so this call did not answer the request. This "
                                     + "call gave the secret to: nova. Those grants stand. Ask the owner whether "
                                     + "those agents keep the secret: grant_secret with level null takes it back "
                                     + "from one agent. The hub") == true)
            #expect(app.asked == checks + ["sign grant nova w5", "grant nova use", "answer", "refresh"])
            #expect(app.needsRead == [12] && app.ungrants == 0)
        }
        for error in GrantSecretSample.notKnown {
            let app = StandInAnswerDesk()
            app.answerAnswers = [error]
            let words = await app.refusal(one)
            #expect(words == AnswerSecret.answerNotKnown(["nova"]), "\(error)")
            #expect(words?.contains("not known") == true && words?.contains("Call answer_secret_request again in "
                                                                             + "the same way") == true)
            #expect(app.asked == checks + ["sign grant nova w5", "grant nova use", "answer", "refresh"])
            let bare = StandInAnswerDesk()
            bare.answerAnswers = [error]
            #expect(await bare.refusal(none) == AnswerSecret.answerNotKnown([]))
            #expect(bare.refreshes == 0)
        }
        // The same call again, after an answer that went: the request has its answer with this secret, and the
        // call sends nothing.
        let again = StandInAnswerDesk()
        again.requests = [.found(.init(open: false, env: AnswerSecretSample.variable, saved: key))]
        #expect(await again.refusal(one) == AnswerSecret.answeredWithThis)
        #expect(again.writes == 0)
    }

    /// **No refusal of the app quotes what the caller sent, but an agent's name that passed the name's form.** A
    /// marker as an id, in a reference, as a level and as a field's name is in no refusal; as an agent's name it is
    /// in the refusals about that agent only.
    @Test func noRefusalQuotesWhatTheCallerSentButAnAgentsName() async {
        let marker = "zq-marker"
        let reference = "bws://2a2a2a2a-7b7b-4c7c-8d7d-7e7e7e7e7e7e"
        var said: [String] = []
        let calls: [([String: JSONValue], (StandInAnswerDesk) -> Void)] = [
            (AnswerSecretSample.call(reference), { _ in }),
            (AnswerSecretSample.call(reference, give: [:]), { _ in }),
            (AnswerSecretSample.call(need: 7_654_321), { $0.requests = [AnswerSecret.RequestRead.none] }),
            (AnswerSecretSample.call(need: 7_654_321), { $0.requests = [.found(.init(isSecret: false))] }),
            (AnswerSecretSample.call(need: 7_654_321), { $0.requests = [.found(.init(env: "X", door: true))] }),
            (AnswerSecretSample.call(need: 7_654_321), { $0.requests = [.found(.init(open: false, saved: reference))] }),
            (AnswerSecretSample.call(reference, need: 7_654_321), { $0.answerAnswers = [AnswerSecret.Answered()] }),
            (AnswerSecretSample.call(need: 7_654_321), { $0.answerAnswers = [SaveBotToken.HubFailure.noAnswer] }),
            (AnswerSecretSample.call(need: 7_654_321), { $0.signAnswers = [SaveBotToken.HubFailure.noAnswer] }),
            (AnswerSecretSample.call(need: 7_654_321), { $0.grantAnswers = [SaveBotToken.HubFailure.noAnswer] }),
            (AnswerSecretSample.with([marker: .int(1)]), { _ in }),
            (AnswerSecretSample.with(["give": .object(["nova": .string(marker)])]), { _ in }),
        ]
        for (fields, change) in calls {
            let app = StandInAnswerDesk()
            change(app)
            if let words = await app.refusal(fields) { said.append(words) }
        }
        #expect(said.count == calls.count)
        for words in said {
            #expect(!words.contains("zq") && !words.contains("2a2a") && !words.contains("7654321")
                    && !words.contains("7_654_321") && !words.contains(key), "\(words)")
        }
        // The agent's name: in the refusal about that agent, before a write and after one.
        let app = StandInAnswerDesk()
        #expect(await app.refusal(AnswerSecretSample.call(give: [marker: "use"])) == AnswerSecret.noAgent(marker))
        var agents = AnswerSecretSample.list().agents
        agents[marker] = .init(role: "worker", machine: "w9")
        let other = StandInAnswerDesk()
        other.teams = [.init(secrets: AnswerSecretSample.list().secrets, agents: agents)]
        other.signAnswers = [SaveBotToken.HubFailure.noAnswer]
        let words = await other.refusal(AnswerSecretSample.call(give: [marker: "use"]))
        #expect(words == AnswerSecret.stopped(.signNotKnown, agent: marker, before: []))
        #expect(words?.contains(marker) == true && words?.contains(key) == false && words?.contains("w9") == false)
    }
}

// ------------------------------------------------------------ the program

/// **The program's side of `answer_secret_request`**, with a stand-in link: what one call sends, that a wrong field
/// reaches no link, and what the program says when its answer is lost.
final class OwnerAnswerSecretProgramTests {
    let home = Fixture.home()
    deinit { try? FileManager.default.removeItem(at: home) }

    static let answered = JSONValue.object(["need": .int(12), "login": .string(AnswerSecretSample.key),
                                            "answered": .bool(true), "given": .array([]),
                                            "note": .string(AnswerSecret.noteAnswered)])

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

    /// **The tool is a write of the program alone, and the last one of its list**: taken by `write` and by the MCP
    /// form, refused by `call`, and no tool of `owner_mcp.py`'s table.
    @Test func theToolIsAWriteOfTheProgramAloneAndTheLastOne() throws {
        let tools = OwnerTools(table: Fixture.table, context: context(ValueLink()))
        let tool = try #require(tools.listed.first { $0.name == AnswerSecret.name })
        #expect(OwnerTools.verb(of: tool) == .write)
        #expect(tools.listed.last?.name == AnswerSecret.name)
        let (status, out, _) = try run(["tools"], ValueLink())
        #expect(status == 0)
        #expect(out.last == "write answer_secret_request: " + AnswerSecret.tool.firstSentence)
        #expect(out.filter { $0.hasPrefix("write answer_secret_request") }.count == 1)
        let (one, full, _) = try run(["tools", "answer_secret_request"], ValueLink())
        #expect(one == 0 && full.contains(AnswerSecret.tool.description))
    }

    /// **`write` sends the three fields and no value part, and reads nothing on this Mac.** The integer and the
    /// object cross the wire as they are. `call` refuses the tool, because it is a write.
    @Test func writeSendsTheThreeFieldsAndNoValuePart() throws {
        let looked = LookedInput()
        let link = ValueLink(.answer(.result(Self.answered)))
        let calls = [AnswerSecretSample.one, AnswerSecretSample.none, AnswerSecretSample.three]
        for (number, fields) in calls.enumerated() {
            let (status, out, said) = try run(["write", "answer_secret_request", JSONValue.object(fields).dumps()],
                                              link, input: looked.input)
            #expect(status == 0 && said.isEmpty && JSONValue.parse(out.joined()) == Self.answered)
            #expect(link.all.count == number + 1)
            #expect(link.all.last?.0 == OwnerChannel.Request(set: "owner", tool: "answer_secret_request",
                                                             fields: fields))
            #expect(link.all.last?.1 == nil && link.all.last?.0.valueBytes == nil)
        }
        let line = try #require(link.all.last?.0.line)
        let read = try OwnerChannel.Request.read(Data(line.dropLast())).get()
        #expect(read.fields == AnswerSecretSample.three && read.fields["need"] == .int(12))
        #expect(looked.count == 0)
        let (refused, _, words) = try run(["call", "answer_secret_request",
                                           JSONValue.object(AnswerSecretSample.one).dumps()], link)
        #expect(refused == 1 && words.first?.hasPrefix("answer_secret_request writes, so founderizer-cli call does "
                                                       + "not take it") == true)
        #expect(link.all.count == 3)
    }

    /// **A call with a wrong field reaches no link**: each refusal of the fields is the program's own, in the
    /// tool's fixed sentence, and nothing is sent.
    @Test func aWrongFieldReachesNoLink() throws {
        let one = AnswerSecretSample.one
        let cases: [([String: JSONValue], String)] = [
            ([:], AnswerSecret.needWord),
            (one.merging(["need": .string("12")]) { $1 }, AnswerSecret.needWord),
            (one.merging(["need": .double(12.5)]) { $1 }, AnswerSecret.needWord),
            (one.merging(["login": .string("secret:" + AnswerSecretSample.key)]) { $1 }, AnswerSecret.loginWord),
            (one.filter { $0.key != "give" }, AnswerSecret.needsGive),
            (one.merging(["give": .null]) { $1 }, AnswerSecret.giveWord),
            (one.merging(["give": .object(["Nova": .string("use")])]) { $1 }, AnswerSecret.giveAgentWord),
            (one.merging(["give": .object(["nova": .null])]) { $1 }, AnswerSecret.giveLevelWord),
            (one.merging(["decline": .string("no")]) { $1 }, AnswerSecret.only),
            (one.merging(["value": .string("x")]) { $1 }, OwnerLinkTools.neverAField),
        ]
        for (fields, words) in cases {
            let link = ValueLink(.answer(.result(Self.answered)))
            let (status, _, said) = try run(["write", "answer_secret_request", JSONValue.object(fields).dumps()], link)
            #expect(status == 1 && link.all.isEmpty, "\(fields)")
            #expect(said == [words], "\(fields)")
        }
        let link = ValueLink()
        let tools = OwnerTools(table: Fixture.table, context: context(link))
        #expect(tools.call("answer_secret_request", .array([]))
                == ("answer_secret_request takes one JSON object of its fields. Nothing was sent.", true))
        #expect(tools.call("answer_secret_request", nil) == (AnswerSecret.needWord, true))
        #expect(link.all.isEmpty)
    }

    /// **The MCP form lists the tool last and takes it**, and reads nothing of its standard input.
    @Test func theMCPFormListsItAndTakesIt() throws {
        let looked = LookedInput()
        let link = ValueLink(.answer(.result(Self.answered)))
        let lines = Lines()
        let mcp = OwnerMCP(tools: OwnerTools(table: Fixture.table, context: context(link, input: looked.input)),
                           version: "0.1.0", sink: { lines.add($0) })
        mcp.take(line: #"{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}"#)
        let calls = [AnswerSecretSample.none, AnswerSecretSample.one.filter { $0.key != "give" }]
        for (number, fields) in calls.enumerated() {
            mcp.take(line: JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .int(Int64(number + 2)), "method": .string("tools/call"),
                "params": .object(["name": .string("answer_secret_request"), "arguments": .object(fields)]),
            ]).dumps())
        }
        mcp.finish()
        let said = lines.wait(for: 3)
        let listed = try #require(said.first { $0["id"] == .int(1) }?["result"]?["tools"]?.array)
        let tool = try #require(listed.last)
        #expect(tool["name"] == .string("answer_secret_request"))
        #expect(tool["annotations"]?["readOnlyHint"] == .bool(false))
        #expect(tool["inputSchema"]?["required"] == .array([.string("need"), .string("login"), .string("give")]))
        let taken = try #require(said.first { $0["id"] == .int(2) }?["result"])
        #expect(taken["isError"] == .bool(false))
        #expect(link.all.count == 1 && link.all.first?.0.fields == AnswerSecretSample.none)
        let missing = try #require(said.first { $0["id"] == .int(3) }?["result"])
        #expect(missing["isError"] == .bool(true))
        #expect(missing["content"]?.array?.first?["text"] == .string(AnswerSecret.needsGive))
        #expect(looked.count == 0)
    }

    /// **A lost answer has this tool's own words.** An answer of the app goes back as it is, and a failure before
    /// the send keeps the link's words.
    @Test func aLostAnswerHasThisToolsOwnWords() {
        for words in [ChannelClient.noAnswer, ChannelClient.closedNoAnswer, ChannelClient.unreadable] {
            let link = ValueLink(.failed(words))
            let tools = OwnerTools(table: Fixture.table, context: context(link))
            for fields in [AnswerSecretSample.one, AnswerSecretSample.none] {
                #expect(tools.call("answer_secret_request", .object(fields)) == (AnswerSecret.notKnownHere, true))
            }
            #expect(link.all.count == 2)
        }
        for refusal in [AnswerSecret.busy, AnswerSecret.answerNotKnown(["nova"]), AnswerSecret.answeredWithThis] {
            let tools = OwnerTools(table: Fixture.table, context: context(ValueLink(.answer(.refused(refusal)))))
            #expect(tools.call("answer_secret_request", .object(AnswerSecretSample.one)) == (refusal, true))
        }
        let took = OwnerTools(table: Fixture.table, context: context(ValueLink(.answer(.result(Self.answered)))))
        #expect(took.call("answer_secret_request", .object(AnswerSecretSample.one))
                == (Self.answered.dumps(indent: 1), false))
        let notRunning = OwnerTools(table: Fixture.table, context: context(ValueLink(.nothingListens)))
        #expect(notRunning.call("answer_secret_request", .object(AnswerSecretSample.one)) == (AppLink.notStarted, true))
    }
}

// ------------------------------------------------------------ the whole way

/// **The whole way**: the program's tool, the real exchange on a socket of the test's own, the board as
/// `LinkTools.add` fills it (the set `owner`, no value part, and one line of writes for this tool and
/// `grant_secret`), and the logic of both tools with stand-in desks.
final class OwnerAnswerSecretLinkTests {
    let home = Fixture.home()
    let folder: URL
    let path: String

    init() {
        // Short: a local socket's path takes at most 104 bytes.
        folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fza-\(UUID().uuidString.prefix(8))", isDirectory: true)
        path = folder.appendingPathComponent("app.sock").path
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: folder)
    }

    /// How each call of this tool ended, as the board's entry saw it.
    @MainActor
    final class CallEnds {
        var all: [(answer: OwnerChannel.Answer, cancelled: Bool)] = []
    }

    private func wired() async -> (board: SetupBoard, desk: StandInAnswerDesk, grants: StandInGrantDesk,
                                   ends: CallEnds) {
        await MainActor.run {
            let line = GrantSecret.Line()
            let app = StandInAnswerDesk(line: line)
            let grants = StandInGrantDesk()
            let ends = CallEnds()
            let board = SetupBoard(read: { OwnerSetupBoardTests.facts() }, show: { _, _ in nil })
            let desk = app.desk, grantDesk = grants.desk
            let added = board.add(set: OwnerSetupTools.set, tool: AnswerSecret.name, value: .none) { fields, value in
                let answer = await AnswerSecret.answer(fields: fields, value: value, desk: desk, line: line)
                ends.all.append((answer, Task.isCancelled))
                return answer
            }
            let other = board.add(set: OwnerSetupTools.set, tool: GrantSecret.name, value: .none) { fields, value in
                await GrantSecret.answer(fields: fields, value: value, desk: grantDesk, line: line)
            }
            #expect(added && other)
            return (board, app, grants, ends)
        }
    }

    private func listener(_ board: SetupBoard) -> ChannelListener {
        ChannelListener(path: path, check: StandInCheck(takes: true)) { request, value in
            await board.answer(request, value: value)
        }
    }

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

    private func comes(_ done: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await MainActor.run(body: done) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await MainActor.run(body: done)
    }

    /// **A call goes the whole way**: the program checks the fields and sends them with no value part, the app
    /// checks them again, gives, answers, and the result comes back as the app made it. A refusal of the app comes
    /// back in its words, and a wrong field never reaches the app.
    @Test func aCallGoesTheWholeWay() async throws {
        let (board, app, _, _) = await wired()
        let link = listener(board)
        defer { link.stop() }
        #expect(link.start() == .listening)
        let tools = tools()
        let (text, isError) = await off { tools.call("answer_secret_request", .object(AnswerSecretSample.three)) }
        #expect(!isError, "\(text)")
        let answer = try #require(JSONValue.parse(text)?.object)
        #expect(answer["need"] == .int(12) && answer["answered"] == .bool(true))
        #expect(answer["given"]?.array?.map { $0["agent"] } == [.string("atlas"), .string("nova"), .string("orion")])
        let asked = await MainActor.run { app.asked }
        #expect(asked == AnswerSecretSample.checks + ["sign grant atlas w6", "grant atlas use", "sign grant nova w5",
                                                      "grant nova read", "sign grant orion w7", "grant orion use",
                                                      "answer", "refresh"])
        // A refusal of the app, in its words.
        await MainActor.run { app.requests = [.found(.init(env: AnswerSecretSample.variable, door: true))] }
        let (door, doorFailed) = await off { tools.call("answer_secret_request", .object(AnswerSecretSample.none)) }
        #expect(doorFailed && door == AnswerSecret.doorNeedsDoor)
        // A wrong field never reaches the app.
        let before = await MainActor.run { app.asked.count }
        let (wrong, wrongFailed) = await off {
            tools.call("answer_secret_request", .object(AnswerSecretSample.with(["need": .string("12")])))
        }
        #expect(wrongFailed && wrong == AnswerSecret.needWord)
        #expect(await MainActor.run { app.asked.count } == before)
    }

    /// **A client that goes after its line does not stop the later writes, and `grant_secret` waits its turn.** The
    /// caller's connection ends while the first write waits: the listener cancels the call's task, the writes go
    /// on with no caller, a call of `grant_secret` meanwhile is refused with the shared sentence, and the answer of
    /// the request is still sent, one time.
    @Test func aClientThatGoesDoesNotStopTheWritesAndGrantSecretIsRefusedMeanwhile() async throws {
        let (board, app, grants, ends) = await wired()
        await MainActor.run { app.holdAt = ["sign"] }
        let link = listener(board)
        defer { link.stop() }
        #expect(link.start() == .listening)
        let request = OwnerChannel.Request(set: "owner", tool: AnswerSecret.name, fields: AnswerSecretSample.one)
        let socket = OwnerChannel.newSocket()
        try #require(socket >= 0)
        try #require(OwnerChannel.connect(socket, to: path) == 0)
        let wire = request.line
        #expect(wire.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) } == wire.count)
        #expect(await comes { app.holds("sign") == 1 })
        close(socket)
        #expect(await comes { link.openCount == 0 })
        #expect(await MainActor.run { app.holds("sign") == 1 && app.line.busy && ends.all.isEmpty })
        // A call of the other tool meanwhile: refused, and it sends nothing.
        let tools = tools()
        let (busy, failed) = await off { tools.call("grant_secret", .object(GrantSecretSample.give)) }
        #expect(failed && busy == GrantSecret.busy)
        #expect(await MainActor.run { grants.writes == 0 })
        await MainActor.run {
            app.holdAt = []
            app.open("sign")
        }
        #expect(await comes { ends.all.count == 1 })
        let first = await MainActor.run { ends.all.last }
        #expect(first?.cancelled == true)
        guard case .result(let answer)? = first?.answer else {
            Issue.record("the call did not end with a result")
            return
        }
        #expect(answer["answered"] == .bool(true))
        let seen = await MainActor.run { (answers: app.answers, steps: app.steps, busy: app.line.busy) }
        #expect(seen.answers == ["12 \(AnswerSecretSample.key)"] && !seen.busy)
        let writes = seen.steps.filter { ["sign", "grant", "answer"].contains($0.name) }
        #expect(writes.map(\.name) == ["sign", "grant", "answer"] && writes.allSatisfy { !$0.cancelled })
        // The line is free: the other tool writes now.
        let (next, nextFailed) = await off { tools.call("grant_secret", .object(GrantSecretSample.give)) }
        #expect(!nextFailed, "\(next)")
    }
}
