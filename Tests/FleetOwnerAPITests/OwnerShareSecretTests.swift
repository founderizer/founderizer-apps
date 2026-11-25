import Darwin
import Foundation
import Testing
@testable import FleetCore
@testable import FleetOwnerAPI

// **`share_secret`** (`OwnerShareSecret.swift`): the fields and their forms, the tool's words, the app's answer to one
// call with a stand-in desk, the program's side of one call, and the whole way on a socket of the test's own. The
// app's own desk (`LinkTools.shareDesk`) and the function that signs (`GrantSigning.send(pool:...)`) are in the app
// target, which has no tests. No test reads a Keychain, signs anything, reaches a hub or sleeps for a fixed time: a
// test waits with a bound of looks.

/// What the tests of `share_secret` share: the example fleet and secrets of `grant_secret`'s tests, example calls,
/// two bases of the resources, and the tool's sentences in lists.
enum ShareSecretSample {
    static let fleet = GrantSecretSample.fleet
    /// An API key of the list, another API key of the same variable name, a login, and a reference of no secret.
    static let key = GrantSecretSample.key
    static let twin = GrantSecretSample.twin
    static let password = GrantSecretSample.password
    static let unknown = GrantSecretSample.unknown
    /// The base of the call's first read of the resources, and the base of a read after a 409.
    static let base = "base-1"
    static let newer = "base-2"

    /// The fleet's list (`grant_secret`'s sample): the API key, its twin and a login.
    static func list() -> ShareSecret.Team { GrantSecretSample.list() }

    /// The fleet's resources: each secret of the list but the ones left out, a standing at this level for the ones
    /// named, and a base.
    static func resources(base: String = ShareSecretSample.base, standing: [String] = [], level: String = "use",
                          without: [String] = []) -> ShareSecret.Resources {
        let ids = Set([key, twin, password].filter { !without.contains($0) }.map(ShareSecret.resourceID))
        let standings = Dictionary(uniqueKeysWithValues: standing.map { (ShareSecret.resourceID($0), level) })
        return ShareSecret.Resources(sha256: base, ids: ids, standings: standings)
    }

    static let share: [String: JSONValue] = ["login": .string(key), "max": .string("use")]
    static let read: [String: JSONValue] = ["login": .string(key), "max": .string("read")]
    static let takeBack: [String: JSONValue] = ["login": .string(key), "max": .null]

    static func with(_ more: [String: JSONValue]) -> [String: JSONValue] { share.merging(more) { $1 } }

    static func refusal(_ fields: [String: JSONValue]) -> String? {
        if case .failure(let refusal) = ShareSecret.read(fields) { return refusal.text }
        return nil
    }

    /// The checks before the writes, as the desk is asked for a call that passes them.
    static let checks = ["ready", "features", "team", "resources", "vault", "key"]

    /// Each sentence of the tool for a refusal before its first write.
    static let before = [ShareSecret.only, ShareSecret.noPart, ShareSecret.loginWord, ShareSecret.needsMax,
                         ShareSecret.maxWord, ShareSecret.notReady, ShareSecret.noStandings, ShareSecret.noSignedPool,
                         ShareSecret.teamUnread, ShareSecret.resourcesUnread, ShareSecret.vaultUnread,
                         ShareSecret.noFleet, ShareSecret.noVaultReading, ShareSecret.vaultSilent,
                         ShareSecret.noOwnerKey, ShareSecret.noOwnerKeyTakeBack, ShareSecret.noSecret,
                         ShareSecret.readNeedsKey, ShareSecret.clockApart, ShareSecret.busy, ShareSecret.ended]
    /// Each sentence for a refusal after a write went out, and the program's words for a lost answer.
    static let after = [ShareSecret.poolRefused, ShareSecret.poolNotKnown, ShareSecret.standingNotKnown,
                        ShareSecret.standingUnwritten, ShareSecret.standingChanged,
                        ShareSecret.standingRefusedTakenBack, ShareSecret.standingRefusedStatementLeft,
                        ShareSecret.standingRefusedHubHasOne, ShareSecret.standingRefusedUnread,
                        ShareSecret.endRefused, ShareSecret.endUnread, ShareSecret.endChanged, ShareSecret.endMoved,
                        ShareSecret.endNotKnown, ShareSecret.unpoolFailed, ShareSecret.notKnownHere,
                        ShareSecret.askOwnerFirst, ShareSecret.askOwnerAfterEnd]
    static let notes = [ShareSecret.noteSame, ShareSecret.noteUse, ShareSecret.noteRead, ShareSecret.noteTold,
                        ShareSecret.noteDelivery, ShareSecret.noteTakenBack, ShareSecret.noteNoStanding,
                        ShareSecret.noteEndedMeanwhile]
}

/// **The app's engine for `share_secret` as stand-ins**: the fleet as the app reads it, the hub's answer to each
/// write, and a record of what the desk was asked, in its order.
@MainActor
final class StandInShareDesk {
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
    /// The place that each look of `ready` gives, in their order; the last one serves each later look.
    var readyPlaces: [Place] = [Place()]
    /// The two features, or nil for a reading of the app that moved.
    var features: ShareSecret.Features? = .init(signs: true, standings: true)
    /// What each read gives, in the order of the reads: a page, or nil for a read that fails. The last one serves
    /// each later read too.
    var teams: [ShareSecret.Team?] = [ShareSecretSample.list()]
    var resourcePages: [ShareSecret.Resources?] = [ShareSecretSample.resources()]
    /// The vault's page, or nil for a read that fails.
    var vault: ShareSecret.Vault? = .init(fleet: ShareSecretSample.fleet, central: .answers)
    var holdsKey = true
    /// Whether this Mac's clock and the hub's differ by more than an hour, or nil for no answer of the hub in this
    /// launch. It is not recorded in `asked`: `clockAsked` says whether a call asked it.
    var clockApart: Bool? = false
    var clockAsked = false
    /// What each signed statement and each standing of the hub gets, in the order of the sends: nil when it was
    /// taken. The last one serves each later send too.
    var signAnswers: [(any Error)?] = [nil]
    var standingAnswers: [(any Error)?] = [nil]
    /// The receipt's `changed` of each standing that the hub took, in their order; the last one serves each later.
    var changed: [Bool] = [true]

    // What the desk was asked.
    var asked: [String] = []
    var statements: [ShareSecret.Statement] = []
    /// Each standing that the desk was asked to send: its base, its reference and its level ("null" for an end).
    var standings: [String] = []
    var places: [Place] = []
    var refreshes = 0
    /// Each awaited closure, in its order, with whether its task was cancelled when it went on.
    var steps: [Step] = []
    /// The closure whose call cancels the task that called it, as the end of the call's connection does.
    var cancelAt: String?
    /// The closures that stop until the test opens them, and the calls that stand there now.
    var holdAt: Set<String> = []
    private var held: [(name: String, go: CheckedContinuation<Void, Never>)] = []

    let line = ShareSecret.Line()

    /// The writes that the desk was asked for: the signed statements and the hub's standings.
    var writes: Int { statements.count + standings.count }

    /// The signed statements that take the secret out of the pool.
    var unpools: Int { statements.filter { !$0.inPool }.count }

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

    var desk: ShareSecret.Desk<Place> {
        ShareSecret.Desk<Place>(
            ready: { [self] in
                asked.append("ready")
                return ready ? next(&readyPlaces) : nil
            },
            features: { [self] _ in
                asked.append("features")
                return features
            },
            team: { [self] place in
                asked.append("team")
                places.append(place)
                await step("team")
                guard let found = next(&teams), let list = found else { throw SaveBotToken.HubFailure.noAnswer }
                return list
            },
            resources: { [self] place in
                asked.append("resources")
                places.append(place)
                await step("resources")
                guard let found = next(&resourcePages), let page = found else {
                    throw SaveBotToken.HubFailure.noAnswer
                }
                return page
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
                return fleet == ShareSecretSample.fleet && holdsKey
            },
            clockApart: { [self] _ in
                clockAsked = true
                return clockApart
            },
            sign: { [self] place, statement in
                asked.append(statement.inPool ? "sign pool" : "sign unpool")
                statements.append(statement)
                places.append(place)
                await step("sign")
                if let found = next(&signAnswers), let error = found { throw error }
            },
            standing: { [self] place, base, login, max in
                asked.append("standing \(max?.rawValue ?? "null") \(base)")
                standings.append("\(base) \(login) \(max?.rawValue ?? "null")")
                places.append(place)
                await step("standing")
                if let found = next(&standingAnswers), let error = found { throw error }
                return next(&changed) ?? true
            },
            refresh: { [self] in
                asked.append("refresh")
                refreshes += 1
            })
    }

    func answer(_ fields: [String: JSONValue], value: OwnerChannel.Value? = nil) async -> OwnerChannel.Answer {
        await ShareSecret.answer(fields: fields, value: value, desk: desk, line: line)
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

/// **The fields of `share_secret`**: `login` and `max`, both required, each in one strict form, and no `to`.
struct OwnerShareSecretFieldTests {
    let key = ShareSecretSample.key

    private func with(_ more: [String: JSONValue]) -> [String: JSONValue] { ShareSecretSample.with(more) }
    private func said(_ fields: [String: JSONValue]) -> String? { ShareSecretSample.refusal(fields) }

    /// A standing at each level, and a take-back, which only a JSON null is.
    @Test func theTwoFieldsAreReadAsTheyCame() {
        #expect(ShareSecret.read(ShareSecretSample.share) == .success(ShareSecret.Read(login: key, max: .use)))
        #expect(ShareSecret.read(ShareSecretSample.read) == .success(ShareSecret.Read(login: key, max: .read)))
        #expect(ShareSecret.read(ShareSecretSample.takeBack) == .success(ShareSecret.Read(login: key, max: nil)))
        #expect(ShareSecret.fields == ["login", "max"])
        // The levels of a standing for a secret are the levels of a grant.
        #expect(ShareSecret.Level.use.rawValue == SecretGrant.use.rawValue)
        #expect(ShareSecret.Level.read.rawValue == SecretGrant.read.rawValue)
    }

    /// **A missing `max` is refused**: a field that was forgotten never takes a standing back. A `max` of another
    /// kind, or another word, has its own sentence.
    @Test func aMissingMaxIsRefusedAndNeverATakeBack() {
        #expect(said(ShareSecretSample.share.filter { $0.key != "max" }) == ShareSecret.needsMax)
        #expect(ShareSecret.needsMax.contains("A call with no max ends no standing."))
        let wrong: [JSONValue] = [.string("write"), .string("USE"), .string("Read"), .string(""), .string("null"),
                                  .string("none"), .string("use "), .string("use\n"), .string("fix"), .int(1),
                                  .bool(false), .array([.string("use")]), .object([:])]
        for max in wrong { #expect(said(with(["max": max])) == ShareSecret.maxWord, "\(max)") }
    }

    /// A field that the tool does not take (`to` among them: the hub keeps one audience), and a field named like a
    /// value, whatever each holds.
    @Test func anUnknownFieldAndAFieldNamedLikeAValueAreRefused() {
        for name in ["to", "agent", "level", "request_id", "resource", "policy", "Max", "standing", "path", ""] {
            #expect(said(with([name: .string("x")])) == ShareSecret.only, "\(name)")
            #expect(said(with([name: .null])) == ShareSecret.only, "\(name)")
        }
        #expect(said(with(["to": .string("workers")])) == ShareSecret.only)
        for name in ["value", "secret", "token", "api_key", "password", "Secret_Max", "login_key"] {
            #expect(said(with([name: .string("x")])) == OwnerLinkTools.neverAField, "\(name)")
            #expect(said(with([name: .null])) == OwnerLinkTools.neverAField, "\(name)")
        }
        // A field named like a value comes first, then an unknown field, then the forms.
        #expect(said(["token": .string("x"), "more": .int(1)]) == OwnerLinkTools.neverAField)
        #expect(said(["more": .int(1)]) == ShareSecret.only)
        // No field of the tool is named like a value, and the sentence for an unknown field names each one.
        for name in ShareSecret.fields {
            #expect(!OwnerLinkTools.namedLikeAValue(name), "\(name)")
            #expect(ShareSecret.only.contains(name), "\(name)")
        }
    }

    /// **The reference is the list's own spelling**, by `grant_secret`'s own form and in its own words: `secret:`
    /// before it, capital letters and anything after it are refused.
    @Test func theReferenceHasTheListsOwnSpelling() {
        let rest = String(key.dropFirst(6))
        let good: [String] = [key, ShareSecretSample.twin, "bws://00000000-0000-0000-0000-000000000000"]
        let bad: [String] = ["", "bws://", "secret:" + key, ShareSecret.resourceID(key), key.uppercased(),
                             "BWS://" + rest, "bws://AAAAAAAA-bbbb-4ccc-8ddd-eeeeeeeeeeee", key + "\n", key + " ",
                             " " + key, key + "0", String(key.dropLast()), rest, "EXAMPLE_API_KEY"]
        for text in good { #expect(said(with(["login": .string(text)])) == nil, "\(text)") }
        for text in bad {
            #expect(said(with(["login": .string(text)])) == ShareSecret.loginWord, "\(text.debugDescription)")
        }
        let others: [JSONValue] = [.null, .int(7), .bool(true), .array([.string(key)])]
        for other in others { #expect(said(with(["login": other])) == ShareSecret.loginWord, "\(other)") }
        #expect(said(ShareSecretSample.share.filter { $0.key != "login" }) == ShareSecret.loginWord)
        #expect(ShareSecret.loginWord == GrantSecret.loginWord)
        #expect(ShareSecret.loginWord.contains("in lower case, with no secret: before it"))
    }

    /// **The checks run in their order**: of two faults in one call, the earlier check's sentence is the answer.
    @Test func theChecksOfTheFieldsRunInTheirOrder() {
        #expect(said([:]) == ShareSecret.loginWord)
        #expect(said(["login": .string("x"), "max": .string("x")]) == ShareSecret.loginWord)
        #expect(said(["login": .string(key), "max": .string("x")]) == ShareSecret.maxWord)
        #expect(said(["login": .string(key)]) == ShareSecret.needsMax)
        #expect(said(["login": .string("x"), "to": .string("workers")]) == ShareSecret.only)
    }

    /// **The program's plan is the two fields as they came**, with `max` as a JSON null for a take-back, and the
    /// app's read takes what the plan sends.
    @Test func thePlanSendsTheTwoFieldsAndANullForATakeBack() throws {
        for fields in [ShareSecretSample.share, ShareSecretSample.read, ShareSecretSample.takeBack] {
            let send = try ShareSecret.plan(fields).get()
            #expect(send == fields && send.count == 2)
            #expect(ShareSecret.read(send) == ShareSecret.read(fields))
        }
        let back = try ShareSecret.plan(ShareSecretSample.takeBack).get()
        #expect(back["max"] == JSONValue.null)
        guard case .failure(let refusal) = ShareSecret.plan(ShareSecretSample.share.filter { $0.key != "max" }) else {
            Issue.record("a plan with no max")
            return
        }
        #expect(refusal.text == ShareSecret.needsMax)
    }

    /// **No refusal of the fields quotes what the caller sent**: the marker as each field's text, as a field's name
    /// and inside a value of another kind.
    @Test func theRefusalsOfTheFieldsQuoteNothing() {
        var cases: [[String: JSONValue]] = []
        for base in [ShareSecretSample.share, ShareSecretSample.takeBack, [:]] {
            for field in ShareSecret.fields + [marker, marker + "_secret", "token", "to"] {
                cases.append(base.merging([field: .string(marker)]) { $1 })
                cases.append(base.merging([field: .array([.string(marker)])]) { $1 })
                cases.append(base.merging([field: .object([marker: .string(marker)])]) { $1 })
            }
            cases.append(base.merging(["login": .string("bws://" + marker)]) { $1 })
            cases.append(base.merging(["login": .string("secret:" + key), "max": .string(marker)]) { $1 })
        }
        var refusals = 0
        for fields in cases {
            guard let text = said(fields) else { continue }
            refusals += 1
            #expect(!text.lowercased().contains(marker) && !text.contains("zq"), "\(text)")
            #expect(text.hasSuffix(" Nothing was sent."), "\(text)")
        }
        #expect(refusals == cases.count && refusals > 40)
    }

    /// **The audience, the levels and the id of a secret's resource are the hub's own**, where this repository has
    /// the hub's file (the public copy of the apps has no root Python file), and the app's own (`ResourceList`).
    @Test func theAudienceTheLevelsAndTheIdAreTheHubsOwn() throws {
        #expect(ShareSecret.audience == ResourceList.everyone)
        #expect(ShareSecret.resourceID(key) == "secret:" + key)
        #expect(ResourceList.feature == "resource_grants")
        guard FileManager.default.fileExists(atPath: OwnerGrantSecretFieldTests.hub.path) else { return }
        let source = try String(contentsOf: OwnerGrantSecretFieldTests.hub, encoding: .utf8)
        #expect(source.contains("RESOURCE_AUDIENCE = \"\(ShareSecret.audience)\""))
        #expect(source.contains(#"RESOURCE_LEVELS = {"secret": ("use", "read"),"#))
        #expect(source.contains(#"ids = {f"secret:{ref}" for ref in (team.get("logins") or {})}"#))
        // the standing that counts (owner feature pool_default): the owner's own level, else the default
        #expect(source.contains(#""grant": standing and {"max": standing["max"], "to": standing["to"], "by": "#
                                + #"standing["by"]},"#))
        // The one 409 of the standing's own act: the base moved (`save_integration`), and the hub refuses a pool
        // statement for an account's key before the vault gets it.
        #expect(source.contains("    if base is not None and base != current:\n"
                                + "        raise Conflict(code=\"team_changed\", sha256=current)"))
        #expect(source.contains("            if pool_statement_refusal(data):"))
    }
}

// ------------------------------------------------------------ the words

/// **The words of `share_secret`**: the tool as the program lists it, its description, and its fixed sentences.
struct OwnerShareSecretWordsTests {
    /// **The tool is a write with two required fields and no value, and it is listed last but one**: the fifth of
    /// `OwnerLinkTools.names` and `tools`, one time in each, and no tool of `owner_mcp.py`'s table.
    /// (`answer_secret_request` came after it.)
    @Test func theToolIsAWriteWithTwoRequiredFieldsAndIsListedLast() throws {
        let tool = ShareSecret.tool
        #expect(tool.name == "share_secret" && ShareSecret.name == "share_secret" && tool.what == "share_secret")
        #expect(tool.annotations == .object(["readOnlyHint": .bool(false)]))
        #expect(OwnerTools.verb(of: tool) == .write)
        #expect(tool.inputSchema["required"] == .array([.string("login"), .string("max")]))
        #expect(tool.inputSchema["additionalProperties"] == .bool(false))
        let properties = try #require(tool.inputSchema["properties"]?.object)
        #expect(Set(properties.keys) == Set(ShareSecret.fields) && properties.count == 2)
        #expect(properties["login"] == .object(["type": .string("string")]))
        #expect(properties["max"] == .object(["type": .array([.string("string"), .string("null")]),
                                              "enum": .array([.string("use"), .string("read"), .null])]))
        #expect(tool.feature == nil && tool.route.isEmpty && !tool.requestIDFromArguments && tool.fields.isEmpty)
        #expect(tool.firstSentence == "Access: Sets who may give one secret of the fleet, with the owner's "
                + "signature, as Who may give it on the Founderizer app's Secrets page does.")
        #expect(OwnerLinkTools.names.firstIndex(of: ShareSecret.name) == 4 && OwnerLinkTools.names.count == 6)
        #expect(OwnerLinkTools.names.filter { $0 == ShareSecret.name }.count == 1)
        #expect(OwnerLinkTools.tools.map(\.name) == OwnerLinkTools.names)
        #expect(OwnerLinkTools.tools[4].description == tool.description)
        // Not a tool of owner_mcp.py's table: a tool of the program only. The program lists it last but one.
        #expect(Fixture.table.tool(ShareSecret.name) == nil)
        let listed = OwnerTools.programTable(Fixture.table).tools.filter { $0.kind.listed }
        #expect(listed.suffix(2).map(\.name) == [ShareSecret.name, AnswerSecret.name])
        #expect(listed.filter { $0.name == ShareSecret.name }.count == 1)
        // It has its own words for a lost answer.
        #expect(OwnerLinkTools.notKnownHere(ShareSecret.name) == ShareSecret.notKnownHere)
        #expect(ShareSecret.notKnownHere != OwnerLinkTools.notKnownOther)
        #expect(ShareSecret.notKnownHere != GrantSecret.notKnownHere)
    }

    /// **What the description says**, sentence for sentence, and what it must not: no word of it says that an agent
    /// can read a login, and it names no other tool of the link.
    @Test func theDescriptionSaysWhatItMust() {
        let words = ShareSecret.tool.description
        let sentences: [String] = [
            "Access: Sets who may give one secret of the fleet, with the owner's signature, as Who may give it on the "
                + "Founderizer app's Secrets page does.",
            "On a fleet with a central vault, the vault sends a secret's value to a server only for a grant that the "
                + "owner's key signed, or for a secret that the owner's key signed into the grantable pool.",
            "A give of the fleet manager has no signature: it brings the value to a server only for a secret of that "
                + "pool, or to a server for which the owner signed a grant of that secret.",
            "This tool makes the Founderizer app sign the secret into the pool with the owner's key on this Mac and "
                + "send it, and then the hub writes the standing: the fleet manager may then give the secret itself "
                + "to any worker or lead, at most at max.",
            "login: the secret's reference as fleet_read(page=\"team\") gives it under logins: bws:// and a UUID in "
                + "lower case, with no secret: before it.",
            "max: use, read or null, and it must be given.",
            "use lets the manager give the secret for use: an agent uses it and never sees it.",
            "read is only for an API key: an agent that the manager gives it to at read has the key's value in its "
                + "sessions as a variable, so set read only when the owner asked for it.",
            "null makes the owner the only one who gives the secret again: the hub ends the standing first, and the "
                + "app then ends the owner's signed pool statement.",
            "The grants that the manager gave from the standing stay in the fleet's list, and the central vault takes "
                + "its copy back from each server for which the owner signed no grant of the secret, where that "
                + "server's vault takes withdrawals, at the first pass of the hub at which that server takes part: a "
                + "server that is off or not pinned keeps its copy until then.",
            "When the hub refuses the standing, the app reads the fleet's resources again and takes its pool "
                + "statement back when the hub has no standing for this secret.",
            "Only the Mac that set up Founderizer Vault holds the owner's key and can sign.",
            "On a hub that takes no signed pool statement, the tool sends nothing: share_resource sets who may give "
                + "a secret there.",
            "While the hub has no reading of a central vault, the tool sends nothing too: the fleet has none, or the "
                + "hub has not read it since it started, and only on a fleet that has none does share_resource set a "
                + "standing for a secret in this tool's place.",
            "It answers login, max, to (workers, for a standing), signed true, changed (whether the hub changed its "
                + "standing) and note.",
            "After a standing, when the central vault holds the value, it sends it to the server of each worker or "
                + "lead that the fleet's list gives the secret to, now and after each give of the fleet manager, "
                + "where that server's vault takes deliveries, at the hub's next pass, usually within a minute (a "
                + "delivery that failed waits up to six hours before the next try).",
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
        // It names no other tool of the link; `share_resource`, the unsigned tool, is no tool of the link.
        for other in OwnerLinkTools.names where other != ShareSecret.name {
            #expect(!words.contains(other), "\(other)")
        }
        #expect(!OwnerLinkTools.names.contains("share_resource"))
        #expect(!words.contains("\n") && !words.contains("  "))
    }

    /// **Each fixed sentence before a write, word for word.** An agent acts on these words: what was sent, what was
    /// signed, and what it does next. A change of one of them is a decision, and this test is where it shows.
    @Test func eachSentenceBeforeAWriteIsHeldWordForWord() {
        #expect(ShareSecret.only == "share_secret takes only login and max. Nothing was sent.")
        #expect(ShareSecret.noPart == "share_secret takes no part after its request line. Nothing was sent.")
        #expect(ShareSecret.loginWord == "login must be the secret's reference as fleet_read(page=\"team\") gives it "
                + "under logins: bws:// and a UUID in lower case, with no secret: before it. Nothing was sent.")
        #expect(ShareSecret.needsMax == "share_secret needs max: use, read, or null so that only the owner gives the "
                + "secret again. A call with no max ends no standing. Nothing was sent.")
        #expect(ShareSecret.maxWord == "max must be use, read or null: the most that the fleet manager may give, with "
                + "read only for an API key, or null so that only the owner gives the secret again. Nothing was sent.")
        #expect(ShareSecret.notReady == "The Founderizer app's reading of the fleet is not current now, or the app "
                + "has no fleet. Call share_secret again in a moment. Nothing was sent.")
        #expect(ShareSecret.noStandings == "This hub keeps no standing for any resource: on it the fleet manager "
                + "gives nothing itself, and only the owner gives a secret. Nothing was sent.")
        #expect(ShareSecret.noSignedPool == "This hub takes no signed pool statement, so the app signs nothing for "
                + "it: share_resource sets who may give a secret on such a fleet. Nothing was sent.")
        #expect(ShareSecret.teamUnread == "The Founderizer app could not read the fleet's list from the hub. Call "
                + "share_secret again in a moment. Nothing was sent.")
        #expect(ShareSecret.resourcesUnread == "The Founderizer app could not read the fleet's resources from the "
                + "hub. Call share_secret again in a moment. Nothing was sent.")
        #expect(ShareSecret.vaultUnread == "The Founderizer app could not read the central vault's status from the "
                + "hub. Call share_secret again in a moment. Nothing was sent.")
        #expect(ShareSecret.noFleet == "The hub did not say which fleet this is, so the app cannot sign for it. Call "
                + "share_secret again in a moment. Nothing was sent.")
        #expect(ShareSecret.noVaultReading == "The hub has no reading of a central vault now: this fleet has none, "
                + "or the hub has not read it since it started. Call share_secret again in a minute. If the same "
                + "answer comes again, ask the owner whether this fleet has Founderizer Vault: only on a fleet that "
                + "has none does share_resource set a standing for a secret in this tool's place. Nothing was sent.")
        #expect(ShareSecret.vaultSilent == "The hub's last reading of the central vault failed, so the vault may not "
                + "answer now. Call share_secret again in a minute. Nothing was sent.")
        #expect(ShareSecret.noOwnerKey == "This Mac holds no owner key for this fleet, so the app on it cannot sign: "
                + "only the Mac that set up Founderizer Vault signs. Nothing was sent.")
        #expect(ShareSecret.noOwnerKeyTakeBack == "This Mac holds no owner key for this fleet, so the app on it "
                + "cannot sign: only the Mac that set up Founderizer Vault signs. share_resource with no max ends the "
                + "hub's standing, and the owner's signed pool statement then stays in the vault until that Mac ends "
                + "it: while it stays, the central vault can still send the value to the server of each worker or "
                + "lead that the fleet's list gives the secret to. Nothing was sent.")
        #expect(ShareSecret.noSecret == "The fleet's list has no secret of that reference: fleet_read(page=\"team\") "
                + "gives the references under logins. Nothing was sent.")
        #expect(ShareSecret.readNeedsKey == "max read is only for an API key: a login is used and never seen. For a "
                + "login the only max is use: call again with max use only when the owner wants that. Nothing was "
                + "sent.")
        #expect(ShareSecret.clockApart == "This Mac's clock and the hub's clock differ by more than an hour, so the "
                + "app signs no pool statement now. Ask the owner to check this Mac's date and time (System Settings, "
                + "General, Date & Time), and then call share_secret again. If this Mac's clock is right, the hub's "
                + "clock is probably wrong: tell the owner. A take-back (max null) does not wait for the clocks. "
                + "Nothing was sent.")
        #expect(ShareSecret.busy == "Another call of share_secret is at its writes now. Call again when it has "
                + "answered. Nothing was sent.")
        #expect(ShareSecret.ended == "The call ended before its first write. Nothing was sent.")
        // At the first write of a standing, when this Mac held the key a moment ago and the app could not sign.
        #expect(ShareSecret.notSignedNow == "This Mac held an owner key for this fleet a moment ago, and the app "
                + "could not sign with it now: the Mac can be locked, the key can be gone, or macOS did not let the "
                + "app read it. Nothing was sent. Call share_secret again later.")
        // The sentences that are `grant_secret`'s own words for the same fact.
        #expect(ShareSecret.loginWord == GrantSecret.loginWord && ShareSecret.noOwnerKey == GrantSecret.noOwnerKey)
        #expect(ShareSecret.noSecret == GrantSecret.noSecret && ShareSecret.ended == GrantSecret.ended)
    }

    /// The sentences after a write went out, the program's words for a lost answer, and the notes, word for word.
    @Test func eachSentenceAfterAWriteAndEachNoteIsHeldWordForWord() {
        #expect(ShareSecret.poolRefused == "The hub refused the owner's signed pool statement, so nothing was "
                + "changed.")
        #expect(ShareSecret.poolNotKnown == "Whether the vault took the owner's signed pool statement is not known, "
                + "and the hub's standing was not changed. If the vault took it, then while it stands with no standing "
                + "the central vault can send the value to the server of each worker or lead that the fleet's list "
                + "gives the secret to. Call share_secret again in the same way: a second statement of the same pool "
                + "is no error, because the vault keeps the newer one.")
        #expect(ShareSecret.standingNotKnown == "The app signed the secret into the grantable pool with the owner's "
                + "key, and whether the hub wrote the standing is not known. While the signed pool statement stands "
                + "with no standing, the central vault can send the value to the server of each worker or lead that "
                + "the fleet's list gives the secret to. Read fleet_read(page=\"resources\"): if this secret's standing "
                + "there is not the one of this call (no standing, or another max), call share_secret again in the "
                + "same way.")
        #expect(ShareSecret.standingUnwritten == "The hub refused the standing, and the app could not read the "
                + "fleet's resources after it, so the standing was not written. The owner's signed pool statement is "
                + "in the vault, and while it stands with no standing the central vault can send the value to the "
                + "server of each worker or lead that the fleet's list gives the secret to. Call share_secret again in "
                + "the same way; call it with max null only if the owner no longer wants the standing.")
        #expect(ShareSecret.standingChanged == "The hub's standing for this secret changed while this call ran, so "
                + "the app did not send its standing again.")
        #expect(ShareSecret.askOwnerFirst == "Before any further call of share_secret for this secret, read "
                + "fleet_read(page=\"resources\") and ask the owner which standing they want.")
        #expect(ShareSecret.askOwnerAfterEnd == "After that, send no standing for this secret again before you asked "
                + "the owner which standing they want.")
        #expect(ShareSecret.standingRefusedTakenBack == "The hub refused the standing, and the app took the owner's "
                + "signed pool statement back: the hub has no standing for this secret, and the secret is out of the "
                + "grantable pool. If the central vault sent the value to a server while the statement stood, it "
                + "takes it back from each server for which the owner signed no grant of it, where that server's "
                + "vault takes withdrawals, at the first pass of the hub at which that server takes part (its vault "
                + "reports to the hub, and the owner's pin is its vault's key).")
        #expect(ShareSecret.standingRefusedStatementLeft == "The hub refused the standing, and the app could not "
                + "take the owner's signed pool statement back: it can stay in the vault with no standing in the hub, "
                + "and while it stays the central vault can send the value to the server of each worker or lead that "
                + "the fleet's list gives the secret to. Read fleet_read(page=\"resources\"). If this secret has no "
                + "standing there, call share_secret with max null to end the signed pool statement. If it has one, "
                + "change nothing: the signed pool statement stands for it.")
        #expect(ShareSecret.standingRefusedHubHasOne == "The hub refused this call. The hub has a standing for this "
                + "secret, which stays as it is, and the owner's signed pool statement stands for it.")
        #expect(ShareSecret.standingRefusedUnread == "The hub refused the standing. The app signed the secret into "
                + "the grantable pool before that and could not read the fleet's resources after it. Read "
                + "fleet_read(page=\"resources\"). If this secret has no standing there, call share_secret with max "
                + "null to end the signed pool statement. If it has one, change nothing: the signed pool statement "
                + "stands for it.")
        #expect(ShareSecret.endRefused == "The hub refused the end of the standing, so nothing was changed.")
        #expect(ShareSecret.endUnread == "The hub refused the end of the standing, and the app could not read the "
                + "fleet's resources after it. This call changed nothing: it did not change the hub's standing, and it "
                + "did not touch the owner's signed pool statement. Call share_secret again.")
        #expect(ShareSecret.endChanged == "The hub's standing for this secret changed while this call ran, so the app "
                + "sent no end of it again: this call changed nothing, and it did not touch the owner's signed pool "
                + "statement. Read fleet_read(page=\"resources\") and ask the owner which standing they want.")
        #expect(ShareSecret.endMoved == "The hub refused the end of the standing, and the app could not end it in one "
                + "more try either. This call changed nothing: it did not change the hub's standing, and it did not "
                + "touch the owner's signed pool statement. Call share_secret again.")
        #expect(ShareSecret.endNotKnown == "Whether the hub ended the standing is not known, and the owner's signed "
                + "pool statement is not ended. Call share_secret again in the same way.")
        #expect(ShareSecret.unpoolFailed == "The hub has no standing for this secret now, so only the owner gives it. "
                + "The vault did not take the end of the owner's signed pool statement, or whether it did is not "
                + "known: a pool statement of this secret can stay there, and while it stays the central vault can "
                + "still send the value to the server of each worker or lead that the fleet's list gives the secret "
                + "to. Call share_secret with max null again to end it: the hub's end is then no change, and the end "
                + "of the statement is sent again.")
        #expect(ShareSecret.notKnownHere == "The Founderizer app did not answer in time, or the link ended, so what "
                + "the app signed and wrote for this call is not known. Call share_secret again in the same way: "
                + "that is safe for a standing and for a take-back, and the app then signs the pool statement or its "
                + "end again. fleet_read with the pages resources and vault shows the hub's standing and the signed "
                + "pool as the hub last read it (central.pool), which can be a minute old.")
        #expect(ShareSecret.noteSame == "The hub had this standing already, so it changed nothing, and the owner's "
                + "signed pool statement is in the vault now.")
        #expect(ShareSecret.noteUse == "The fleet manager may now give the secret itself to any worker or lead, at "
                + "most at use. The grants in the fleet's list do not change with the standing.")
        #expect(ShareSecret.noteRead == "The fleet manager may now give the secret itself to any worker or lead, at "
                + "most at read: the key's value then goes into the sessions of each agent that the manager gives it "
                + "to at read. The grants in the fleet's list do not change with the standing.")
        #expect(ShareSecret.noteTold == "The hub told the fleet manager that the standing changed.")
        #expect(ShareSecret.noteDelivery == "When the central vault holds the value, it sends it to the server of "
                + "each worker or lead that the fleet's list gives the secret to, now and after each give of the fleet "
                + "manager, where that server's vault takes deliveries, at the hub's next pass (usually within a "
                + "minute; a delivery that failed waits up to six hours before the next try).")
        // The end of a copy: a pass skips a server that does not take part then (`central_plan`).
        let from = "from each server for which the owner signed no grant of it, where that server's vault takes "
            + "withdrawals, at the first pass of the hub at which that server takes part (its vault reports to the "
            + "hub, and the owner's pin is its vault's key): a server that is off or not pinned keeps its copy until "
            + "then, and a withdrawal that failed waits up to six hours before the next try."
        let copyBack = "The central vault takes its copy back " + from
        #expect(ShareSecret.copyBackFrom == from && ShareSecret.copyBack == copyBack)
        #expect(ShareSecret.noteTakenBack == "The hub ended the standing, so only the owner gives this secret now, "
                + "and the app ended the owner's signed pool statement. The grants that the fleet manager gave from "
                + "it stay in the fleet's list. " + copyBack)
        #expect(ShareSecret.noteEndedMeanwhile == "The hub's standing for this secret ended while this call ran, so "
                + "the app sent no end of it again, and it sent the end of the owner's signed pool statement to the "
                + "vault. If the secret was in the pool, the central vault takes its copy back " + from)
        #expect(ShareSecret.noteNoStanding == "The hub had no standing for this secret, so it changed nothing, and "
                + "the app sent the end of the owner's signed pool statement to the vault. If the secret was in the "
                + "pool, the central vault takes its copy back " + from)
    }

    /// **"Nothing was sent." exactly when nothing was sent**: each refusal before the first write ends with those
    /// words, and no sentence after a write has them. No sentence says that the app signed for a call that signed
    /// nothing, none says that an agent can read a login, and none names another tool of the link.
    @Test func theSentencesSayNothingWasSentExactlyWhenNothingWas() {
        let before = ShareSecretSample.before, after = ShareSecretSample.after, notes = ShareSecretSample.notes
        #expect(Set(before + after + notes).count == before.count + after.count + notes.count)
        for words in before + [OwnerLinkTools.neverAField] {
            #expect(words.hasSuffix(" Nothing was sent."), "\(words)")
            #expect(words.components(separatedBy: "Nothing was sent").count == 2, "\(words)")
            for claim in ["app signed", "signed true", "signed the secret", "took the owner's", "ended the"] {
                #expect(!words.contains(claim), "\(words)")
            }
        }
        for words in after + notes {
            #expect(!words.contains("Nothing was sent") && !words.contains("nothing was sent"), "\(words)")
        }
        // The one sentence of the first write of a standing that the app could not sign: nothing was sent, and its
        // last words are the next step. It does not say that this Mac holds no key.
        let notSigned = ShareSecret.notSignedNow
        #expect(notSigned.components(separatedBy: "Nothing was sent.").count == 2)
        #expect(notSigned.hasSuffix(" Nothing was sent. Call share_secret again later."))
        #expect(notSigned.hasPrefix("This Mac held an owner key") && !notSigned.contains("holds no owner key"))
        #expect(!before.contains(notSigned) && !after.contains(notSigned))
        for claim in ["app signed", "signed true", "signed the secret", "not known"] {
            #expect(!notSigned.contains(claim), "\(claim)")
        }
        let hubSaid = GrantSecret.withHubWords(ShareSecret.poolRefused, status: 409, "an account's key")
        let others = OwnerLinkTools.names.filter { $0 != ShareSecret.name }
        #expect(others.count == 5)
        for words in before + after + notes + [hubSaid, notSigned] {
            for other in others { #expect(!words.contains(other), "\(words)") }
            for never in ["read a login", "reads a login", "read the login", "reads the login", "read the secret",
                          "reads the secret"] {
                #expect(!words.contains(never), "\(words)")
            }
            #expect(!words.contains("\n") && !words.contains("  "), "\(words)")
        }
        // The unsigned tool is named only where a rule names it: a hub with no signed pool statement, a page with no
        // reading of a central vault (only for a fleet that has none), and a take-back on a Mac with no owner key.
        let named = (before + after + notes).filter { $0.contains("share_resource") }
        #expect(Set(named) == [ShareSecret.noSignedPool, ShareSecret.noVaultReading, ShareSecret.noOwnerKeyTakeBack])
        #expect(ShareSecret.noVaultReading.contains("or the hub has not read it since it started"))
        #expect(ShareSecret.noVaultReading.contains("only on a fleet that has none does share_resource set a standing "
                                                    + "for a secret in this tool's place"))
        #expect(!ShareSecret.tool.description.contains("does share_resource set who may give a secret"))
        #expect(!ShareSecret.noVaultReading.contains("This fleet has no central vault"))
        // No sentence tells the caller to end a pool statement with no look at the hub's standing first.
        #expect(ShareSecret.standingRefusedUnread.contains("If it has one, change nothing"))
        // The take-back's sentence for a Mac with no owner key is the standing's, with what that Mac can still do.
        let common = ShareSecret.noOwnerKey.replacingOccurrences(of: " Nothing was sent.", with: "")
        #expect(ShareSecret.noOwnerKeyTakeBack.hasPrefix(common)
                && ShareSecret.noOwnerKeyTakeBack != ShareSecret.noOwnerKey)
        #expect(ShareSecret.notKnownHere.contains("not known"))
        #expect(ShareSecret.notKnownHere.contains("safe for a standing and for a take-back"))
        // The pages that the words name are pages of `fleet_read`, and the one of the vault is the hub's page of it.
        #expect(Fixture.table.pages["resources"]?.route == "/ui/resources")
        #expect(Fixture.table.pages["vault"]?.route == "/ui/vault" && Fixture.table.pages["team"] != nil)
        #expect(ShareSecret.notKnownHere.contains("fleet_read with the pages resources and vault shows the hub's "
                                                  + "standing and the signed pool as the hub last read it "
                                                  + "(central.pool), which can be a minute old."))
    }
}

// ------------------------------------------------------------ the app's answer

/// **The app's answer to one call of `share_secret`**, with a stand-in desk: each step in its order, with the desk's
/// calls counted, so that "Nothing was sent." is held by a desk whose writes were never called.
@MainActor
struct OwnerShareSecretAppTests {
    let share = ShareSecretSample.share
    let read = ShareSecretSample.read
    let takeBack = ShareSecretSample.takeBack
    let checks = ShareSecretSample.checks
    let key = ShareSecretSample.key
    let fleet = ShareSecretSample.fleet
    let base = ShareSecretSample.base
    let newer = ShareSecretSample.newer

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

    // ------------------------------------------------------------ the calls that go

    /// **A standing at `use`**: the checks, then the signed `pool` statement, then the hub's standing against the
    /// base of the call's read, then the app's refresh. The answer has the fields of the tool, and nothing else.
    @Test func aStandingSignsFirstAndWritesTheHubSecond() async throws {
        let app = StandInShareDesk()
        let answer = try await app.went(share)
        #expect(app.asked == checks + ["sign pool", "standing use \(base)", "refresh"])
        #expect(app.statements == [ShareSecret.Statement(fleet: fleet, login: key, inPool: true)])
        #expect(app.standings == ["\(base) \(key) use"])
        #expect(app.refreshes == 1 && !app.line.busy)
        let note = [ShareSecret.noteUse, ShareSecret.noteTold, ShareSecret.noteDelivery].joined(separator: " ")
        let expected: [String: JSONValue] = [
            "login": .string(key), "max": .string("use"), "to": .string("workers"), "signed": .bool(true),
            "changed": .bool(true), "note": .string(note),
        ]
        #expect(answer == expected)
        // A login at `use` goes too.
        let login = StandInShareDesk()
        let went = try await login.went(ShareSecretSample.with(["login": .string(ShareSecretSample.password)]))
        #expect(went["signed"] == JSONValue.bool(true))
        #expect(login.standings == ["\(base) \(ShareSecretSample.password) use"])
    }

    /// **The reads and the writes of a call go to the place of its one look at the app's reading.** The store shows
    /// another database after the call's look: the call's three reads and its two writes still go to the place that
    /// it took, and only the next call takes the new one.
    @Test func theReadsAndWritesGoToThePlaceOfTheCallsLook() async throws {
        let app = StandInShareDesk()
        let first = StandInShareDesk.Place(), later = StandInShareDesk.Place(database: "gen-2")
        app.readyPlaces = [first, later]
        _ = try await app.went(share)
        #expect(app.asked == checks + ["sign pool", "standing use \(base)", "refresh"])
        #expect(app.places == [first, first, first, first, first])
        _ = try await app.went(takeBack)
        #expect(app.places.count == 10 && app.places.suffix(5).allSatisfy { $0 == later })
        // A refused standing reads the resources again, and signs its end, at the place of the call's look too.
        let refused = StandInShareDesk()
        refused.readyPlaces = [first, later]
        refused.standingAnswers = [SaveBotToken.HubFailure.refused(400, "no")]
        _ = await refused.answer(share)
        #expect(refused.asked == checks + ["sign pool", "standing use \(base)", "resources", "sign unpool"])
        #expect(refused.places == Array(repeating: first, count: 7))
    }

    /// **A standing at `read`** of an API key: the same writes, and the note that the key's value goes into the
    /// sessions of each agent that the manager gives it to at `read`.
    @Test func aStandingAtReadSaysThatTheKeyGoesIntoSessions() async throws {
        let app = StandInShareDesk()
        let answer = try await app.went(read)
        #expect(app.asked == checks + ["sign pool", "standing read \(base)", "refresh"])
        let expected: [String: JSONValue] = [
            "login": .string(key), "max": .string("read"), "to": .string("workers"), "signed": .bool(true),
            "changed": .bool(true),
            "note": .string([ShareSecret.noteRead, ShareSecret.noteTold, ShareSecret.noteDelivery]
                .joined(separator: " ")),
        ]
        #expect(answer == expected)
    }

    /// **A standing that changes nothing** is the repair of a standing with no signature: the hub had it, it changed
    /// nothing and told nobody, and the app signed the pool statement.
    @Test func aStandingThatChangesNothingStillSigns() async throws {
        let app = StandInShareDesk()
        app.resourcePages = [ShareSecretSample.resources(standing: [key])]
        app.changed = [false]
        let answer = try await app.went(share)
        #expect(app.asked == checks + ["sign pool", "standing use \(base)", "refresh"])
        #expect(answer["changed"] == JSONValue.bool(false) && answer["signed"] == JSONValue.bool(true))
        #expect(answer["note"] == JSONValue.string([ShareSecret.noteSame, ShareSecret.noteUse, ShareSecret.noteDelivery]
            .joined(separator: " ")))
        let same = StandInShareDesk()
        same.changed = [false]
        let unchanged = try await same.went(read)
        #expect(unchanged["note"] == JSONValue.string([ShareSecret.noteSame, ShareSecret.noteRead,
                                                       ShareSecret.noteDelivery].joined(separator: " ")))
    }

    /// **A take-back**: the checks, then the hub's end of the standing, then the signed `unpool`. It makes no check of
    /// the secret: an end goes for a secret that the list or the resources do not have, and for a login.
    @Test func aTakeBackEndsTheStandingFirstAndThePoolStatementSecond() async throws {
        let app = StandInShareDesk()
        app.resourcePages = [ShareSecretSample.resources(standing: [key])]
        let answer = try await app.went(takeBack)
        // A take-back never asks for the clocks, so it goes at a launch and while they are apart.
        #expect(!app.clockAsked)
        #expect(app.asked == checks + ["standing null \(base)", "sign unpool", "refresh"])
        #expect(app.standings == ["\(base) \(key) null"])
        #expect(app.statements == [ShareSecret.Statement(fleet: fleet, login: key, inPool: false)])
        let expected: [String: JSONValue] = [
            "login": .string(key), "max": .null, "signed": .bool(true), "changed": .bool(true),
            "note": .string(ShareSecret.noteTakenBack),
        ]
        #expect(answer == expected)
        #expect(answer["to"] == nil)
        // The hub had no standing: it changed nothing, and the end of the statement went.
        let none = StandInShareDesk()
        none.changed = [false]
        let same = try await none.went(takeBack)
        #expect(same["changed"] == JSONValue.bool(false))
        #expect(same["note"] == JSONValue.string(ShareSecret.noteNoStanding))
        #expect(none.unpools == 1 && none.statements.count == 1)
        // No check of the secret: one that the list and the resources lack, a login, and the key itself.
        for login in [ShareSecretSample.unknown, ShareSecretSample.password, key] {
            let other = StandInShareDesk()
            other.teams = [ShareSecret.Team(secrets: [:], agents: [:])]
            other.resourcePages = [ShareSecret.Resources(sha256: base, ids: [])]
            let went = await other.result(ShareSecretSample.with(["login": .string(login), "max": .null]))
            #expect(went?["signed"] == JSONValue.bool(true), "\(login)")
            #expect(other.asked == checks + ["standing null \(base)", "sign unpool", "refresh"], "\(login)")
        }
    }

    // ------------------------------------------------------------ each step, in its order

    /// One refusal before the first write: what the desk was asked up to it, and that no write was called.
    private func refused(_ fields: [String: JSONValue], _ words: String, asked: [String],
                         value: OwnerChannel.Value? = nil, _ change: (StandInShareDesk) -> Void = { _ in }) async {
        let app = StandInShareDesk()
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
        await refused(share.filter { $0.key != "max" }, ShareSecret.needsMax, asked: [])
        await refused(ShareSecretSample.with(["max": .string("write")]), ShareSecret.maxWord, asked: [])
        await refused(ShareSecretSample.with(["login": .string("secret:" + key)]), ShareSecret.loginWord, asked: [])
        await refused(ShareSecretSample.with(["login": .string(key.uppercased())]), ShareSecret.loginWord, asked: [])
        await refused(ShareSecretSample.with(["to": .string("workers")]), ShareSecret.only, asked: [])
        await refused(ShareSecretSample.with(["token": .string("x")]), OwnerLinkTools.neverAField, asked: [])
        await refused(share, ShareSecret.noPart, asked: [], value: OwnerChannel.Value(copying: Array("more".utf8)))
        await refused(takeBack, ShareSecret.noPart, asked: [], value: OwnerChannel.Value(copying: Array("more".utf8)))
    }

    /// **Steps 2 to 4, each with its own sentence, in their order.** Each case fails one check; the desk is asked
    /// up to that check, and no write is called.
    @Test func eachCheckRefusesInItsOrderAndSendsNothing() async {
        // 2. A current reading, with a hub that serves the Secrets page.
        await refused(share, ShareSecret.notReady, asked: ["ready"]) { $0.ready = false }
        // 3. The two features: a reading that moved is "not ready", and a hub that lacks one has its words. A hub
        // with neither keeps no standing at all.
        let listed = ["ready", "features"]
        await refused(share, ShareSecret.notReady, asked: listed) { $0.features = nil }
        await refused(share, ShareSecret.noStandings, asked: listed) {
            $0.features = .init(signs: true, standings: false)
        }
        await refused(share, ShareSecret.noStandings, asked: listed) {
            $0.features = .init(signs: false, standings: false)
        }
        await refused(takeBack, ShareSecret.noStandings, asked: listed) {
            $0.features = .init(signs: false, standings: false)
        }
        await refused(share, ShareSecret.noSignedPool, asked: listed) {
            $0.features = .init(signs: false, standings: true)
        }
        await refused(takeBack, ShareSecret.noSignedPool, asked: listed) {
            $0.features = .init(signs: false, standings: true)
        }
        // 4. The three reads.
        await refused(share, ShareSecret.teamUnread, asked: listed + ["team"]) { $0.teams = [nil] }
        await refused(takeBack, ShareSecret.teamUnread, asked: listed + ["team"]) { $0.teams = [nil] }
        await refused(share, ShareSecret.resourcesUnread, asked: listed + ["team", "resources"]) {
            $0.resourcePages = [nil]
        }
        await refused(takeBack, ShareSecret.resourcesUnread, asked: listed + ["team", "resources"]) {
            $0.resourcePages = [nil]
        }
        let reads = listed + ["team", "resources", "vault"]
        await refused(share, ShareSecret.vaultUnread, asked: reads) { $0.vault = nil }
        await refused(share, ShareSecret.noFleet, asked: reads) { $0.vault = .init(fleet: nil, central: .answers) }
        await refused(share, ShareSecret.noVaultReading, asked: reads) {
            $0.vault = .init(fleet: ShareSecretSample.fleet, central: .noReading)
        }
        await refused(takeBack, ShareSecret.noVaultReading, asked: reads) {
            $0.vault = .init(fleet: ShareSecretSample.fleet, central: .noReading)
        }
        await refused(share, ShareSecret.vaultSilent, asked: reads) {
            $0.vault = .init(fleet: ShareSecretSample.fleet, central: .silent)
        }
        await refused(share, ShareSecret.noOwnerKey, asked: checks) { $0.holdsKey = false }
        await refused(read, ShareSecret.noOwnerKey, asked: checks) { $0.holdsKey = false }
        await refused(takeBack, ShareSecret.noOwnerKeyTakeBack, asked: checks) { $0.holdsKey = false }
        // A key that this Mac holds for another fleet is no key for this one.
        await refused(share, ShareSecret.noOwnerKey, asked: checks) {
            $0.vault = .init(fleet: "ffffffffffffffff", central: .answers)
        }
        // For a standing only: the secret in the list and in the resources, and `read` only for an API key.
        await refused(ShareSecretSample.with(["login": .string(ShareSecretSample.unknown)]), ShareSecret.noSecret,
                      asked: checks)
        await refused(share, ShareSecret.noSecret, asked: checks) {
            $0.resourcePages = [ShareSecretSample.resources(without: [ShareSecretSample.key])]
        }
        await refused(share, ShareSecret.noSecret, asked: checks) {
            $0.teams = [ShareSecret.Team(secrets: [:], agents: [:])]
        }
        await refused(ShareSecretSample.with(["login": .string(ShareSecretSample.password), "max": .string("read")]),
                      ShareSecret.readNeedsKey, asked: checks)
        // Last of a standing's: this Mac's clock and the hub's differ by more than an hour; and with no answer of the
        // hub in this launch, a standing is not ready (it fails closed).
        await refused(share, ShareSecret.clockApart, asked: checks) { $0.clockApart = true }
        await refused(share, ShareSecret.notReady, asked: checks) { $0.clockApart = nil }
    }

    /// **The order of the checks**: of two faults in one call, the earlier check's sentence is the answer.
    @Test func theChecksOfTheAppRunInTheirOrder() async {
        let all = ShareSecretSample.with(["login": .string(ShareSecretSample.password), "max": .string("read")])
        // Every fault at once: the reading first, and then one fault less at each step.
        await refused(all, ShareSecret.notReady, asked: ["ready"]) {
            $0.ready = false; $0.features = .init(signs: false, standings: false); $0.teams = [nil]
            $0.resourcePages = [nil]; $0.vault = nil; $0.holdsKey = false
        }
        await refused(all, ShareSecret.noStandings, asked: ["ready", "features"]) {
            $0.features = .init(signs: false, standings: false); $0.teams = [nil]; $0.resourcePages = [nil]
            $0.vault = nil; $0.holdsKey = false
        }
        await refused(all, ShareSecret.noSignedPool, asked: ["ready", "features"]) {
            $0.features = .init(signs: false, standings: true); $0.teams = [nil]; $0.resourcePages = [nil]
            $0.vault = nil; $0.holdsKey = false
        }
        await refused(all, ShareSecret.teamUnread, asked: ["ready", "features", "team"]) {
            $0.teams = [nil]; $0.resourcePages = [nil]; $0.vault = nil; $0.holdsKey = false
        }
        await refused(all, ShareSecret.resourcesUnread, asked: ["ready", "features", "team", "resources"]) {
            $0.resourcePages = [nil]; $0.vault = nil; $0.holdsKey = false
        }
        let reads = ["ready", "features", "team", "resources", "vault"]
        await refused(all, ShareSecret.vaultUnread, asked: reads) { $0.vault = nil; $0.holdsKey = false }
        await refused(all, ShareSecret.noFleet, asked: reads) {
            $0.vault = .init(fleet: nil, central: .noReading); $0.holdsKey = false
        }
        await refused(all, ShareSecret.noVaultReading, asked: reads) {
            $0.vault = .init(fleet: ShareSecretSample.fleet, central: .noReading); $0.holdsKey = false
        }
        await refused(all, ShareSecret.vaultSilent, asked: reads) {
            $0.vault = .init(fleet: ShareSecretSample.fleet, central: .silent); $0.holdsKey = false
        }
        await refused(all, ShareSecret.noOwnerKey, asked: checks) {
            $0.holdsKey = false; $0.resourcePages = [ShareSecretSample.resources(without: [ShareSecretSample.password])]
        }
        // The secret before its kind: a login that the resources lack is no secret, and then a login at read.
        await refused(all, ShareSecret.noSecret, asked: checks) {
            $0.resourcePages = [ShareSecretSample.resources(without: [ShareSecretSample.password])]
        }
        await refused(all, ShareSecret.readNeedsKey, asked: checks)
        // The clocks after every other check of a standing.
        await refused(all, ShareSecret.readNeedsKey, asked: checks) { $0.clockApart = true }
    }

    // ------------------------------------------------------------ one call at a time, and a caller that goes

    /// **One call writes at a time.** While the first write of a call waits, another call is refused with `busy`
    /// and sends nothing; its own checks ran. When the first call answered, the next one goes.
    @Test func aCallIsRefusedWhileAnotherIsAtItsWrites() async throws {
        let app = StandInShareDesk()
        app.holdAt = ["sign"]
        let first = app.call(share)
        #expect(await comes { app.holds("sign") == 1 })
        #expect(app.line.busy && app.asked == checks + ["sign pool"])
        // A second call, a standing or a take-back: its checks run, and no write of its own is called.
        for fields in [read, takeBack] {
            let answer = await app.answer(fields)
            #expect(answer == .refused(ShareSecret.busy))
        }
        #expect(app.asked == checks + ["sign pool"] + checks + checks)
        #expect(app.statements.count == 1 && app.standings.isEmpty && app.line.busy)
        app.holdAt = []
        app.open("sign")
        let went = await first.value
        #expect(fields(went)?["signed"] == JSONValue.bool(true))
        #expect(!app.line.busy && app.standings == ["\(base) \(key) use"])
        // The line is free again: the next call writes.
        let next = await app.result(takeBack)
        #expect(next?["signed"] == JSONValue.bool(true))
        #expect(app.standings.count == 2 && app.statements.count == 2 && !app.line.busy)
        // A call whose write the hub refused leaves the line free too.
        app.signAnswers = [SaveBotToken.HubFailure.refused(409, "an account's key")]
        let last = await app.refusal(share)
        #expect(last != nil && !app.line.busy)
    }

    /// **Two lines are two.** The app gives `share_secret` a line of its own and `grant_secret` another: while a
    /// call holds one line at its writes, the other line is free, and a call on it writes to its end.
    @Test func whileOneLineIsBusyAnotherLineWrites() async throws {
        let held = StandInShareDesk()
        held.holdAt = ["sign"]
        let waiting = held.call(share)
        #expect(await comes { held.holds("sign") == 1 })
        let free = StandInShareDesk()
        #expect(held.line.busy && !free.line.busy)
        let went = try await free.went(takeBack)
        #expect(went["signed"] == JSONValue.bool(true) && held.line.busy && !free.line.busy)
        // A line of `grant_secret`'s type, as the app's other tool has it, writes too.
        let grants = StandInGrantDesk()
        let given = try await grants.went(GrantSecretSample.give)
        #expect(given["signed"] == JSONValue.bool(true) && held.line.busy)
        // The held call goes on to its end when its write is answered, and its line is free then.
        held.holdAt = []
        held.open("sign")
        let ended = await waiting.value
        #expect(fields(ended)?["signed"] == JSONValue.bool(true) && !held.line.busy)
        // Two lines with nothing between them: one that runs its writes, and one that is free to begin.
        let one = ShareSecret.Line(), other = ShareSecret.Line()
        let running = one.begin { await Task.yield(); return .refused("one") }
        #expect(running != nil && one.busy && !other.busy)
        let second = other.begin { .refused("other") }
        #expect(second != nil && other.busy)
        #expect(await second?.value == .refused("other") && !other.busy)
        #expect(await running?.value == .refused("one") && !one.busy)
    }

    /// **A caller that went away before the first write sends nothing.** The call's task is cancelled during one of
    /// its three reads, as the end of its connection does: the checks pass, and no write is called.
    @Test func aCallerThatWentAwayBeforeTheFirstWriteSendsNothing() async {
        for fields in [share, takeBack] {
            for place in ["team", "resources", "vault"] {
                let app = StandInShareDesk()
                app.cancelAt = place
                let answer = await app.call(fields).value
                #expect(answer == .refused(ShareSecret.ended), "\(place)")
                #expect(app.asked == checks && app.writes == 0 && app.refreshes == 0 && !app.line.busy, "\(place)")
            }
        }
    }

    /// **From its first write on, a call goes to its end also when its caller went away.** The first write of a
    /// standing waits; the caller's task is cancelled; the write goes on, and the second write still runs, one time.
    /// The same for a take-back, whose first write is the hub's end, and for a standing whose standing the hub
    /// refuses after its caller went.
    @Test func aCallerThatWentAwayAfterTheFirstWriteStillGetsTheSecondWrite() async throws {
        let app = StandInShareDesk()
        app.holdAt = ["sign"]
        let call = app.call(share)
        #expect(await comes { app.holds("sign") == 1 })
        #expect(app.statements.count == 1 && app.standings.isEmpty)
        call.cancel()
        // The cancel ended nothing: the first write still waits, and the line is still the call's.
        for _ in 0..<5 { await Task.yield() }
        #expect(app.holds("sign") == 1 && app.line.busy && call.isCancelled)
        app.open("sign")
        let ended = await call.value
        let answer = try #require(fields(ended))
        #expect(answer["signed"] == JSONValue.bool(true) && answer["to"] == JSONValue.string("workers"))
        #expect(app.asked == checks + ["sign pool", "standing use \(base)", "refresh"])
        #expect(app.standings.count == 1 && app.statements.count == 1 && !app.line.busy)
        let writes = app.steps.filter { ["sign", "standing"].contains($0.name) }
        #expect(writes.map(\.name) == ["sign", "standing"])
        #expect(writes.allSatisfy { !$0.cancelled }, "\(writes)")

        // A take-back: the hub's end waits, the caller goes, and the signed end still runs one time.
        let back = StandInShareDesk()
        back.holdAt = ["standing"]
        let second = back.call(takeBack)
        #expect(await comes { back.holds("standing") == 1 })
        second.cancel()
        back.open("standing")
        let taken = await second.value
        #expect(fields(taken)?["signed"] == JSONValue.bool(true))
        #expect(back.asked == checks + ["standing null \(base)", "sign unpool", "refresh"])
        #expect(back.statements.count == 1 && back.standings.count == 1)
        #expect(back.steps.filter { ["sign", "standing"].contains($0.name) }.allSatisfy { !$0.cancelled })

        // A standing that the hub refuses after its caller went: the read and the signed end still run.
        let third = StandInShareDesk()
        third.holdAt = ["sign"]
        third.standingAnswers = [SaveBotToken.HubFailure.refused(400, "no")]
        let lost = third.call(share)
        #expect(await comes { third.holds("sign") == 1 })
        lost.cancel()
        third.holdAt = []
        third.open("sign")
        let said = await lost.value
        #expect(said == .refused(GrantSecret.withHubWords(ShareSecret.standingRefusedTakenBack, status: 400, "no")))
        #expect(third.asked == checks + ["sign pool", "standing use \(base)", "resources", "sign unpool"])
        #expect(third.steps.dropFirst(3).allSatisfy { !$0.cancelled }, "\(third.steps)")
    }

    // ------------------------------------------------------------ when a write fails

    /// **A standing, the signed pool statement.** A certain refusal: nothing was changed, with the hub's words (the
    /// hub refuses here a statement for an account's key), and the hub's standing is not asked. Not known: the same
    /// call again. A key that this Mac holds and that the app could not sign with: nothing was sent, in words that do
    /// not say that this Mac holds no key, and never "not known".
    @Test func aStandingWhosePoolStatementFails() async {
        let certain: [(Int, String)] = [(409, "an account's key goes into no pool"),
                                        (409, "the central vault refused: the vault holds a statement that is as new"),
                                        (400, "statement is the owner's signed statement"), (404, "not found")]
        for (status, said) in certain {
            let app = StandInShareDesk()
            app.signAnswers = [SaveBotToken.HubFailure.refused(status, said)]
            let answer = await app.answer(share)
            #expect(answer == .refused("The hub refused the owner's signed pool statement, so nothing was changed. The "
                                       + "hub's words (status \(status)): \(said)"))
            #expect(app.asked == checks + ["sign pool"] && app.standings.isEmpty && app.refreshes == 0)
        }
        for failure in GrantSecretSample.notKnown {
            let app = StandInShareDesk()
            app.signAnswers = [failure]
            let answer = await app.answer(share)
            #expect(answer == .refused(ShareSecret.poolNotKnown), "\(failure)")
            #expect(app.asked == checks + ["sign pool"] && app.standings.isEmpty, "\(failure)")
        }
        let app = StandInShareDesk()
        app.signAnswers = [ShareSecret.NotSigned()]
        let answer = await app.answer(share)
        #expect(answer == .refused("This Mac held an owner key for this fleet a moment ago, and the app could not "
                                   + "sign with it now: the Mac can be locked, the key can be gone, or macOS did not "
                                   + "let the app read it. Nothing was sent. Call share_secret again later."))
        #expect(answer != .refused(ShareSecret.noOwnerKey) && answer != .refused(ShareSecret.poolNotKnown))
        #expect(app.asked == checks + ["sign pool"] && app.standings.isEmpty && app.refreshes == 0)
        #expect(!app.line.busy)
        // The same call later, when the key can sign, goes.
        app.signAnswers = [nil]
        let later = await app.result(share)
        #expect(later?["signed"] == JSONValue.bool(true))
    }

    /// **A 409 of a standing whose read after it fails** (point 2): no second send and no signed end. The words say
    /// that the standing was not written, that the pool statement is in the vault, and that the next step is the
    /// same call again.
    @Test func aStandingWhose409IsFollowedByAReadThatFails() async {
        let moved = SaveBotToken.HubFailure.refused(409, "team.json changed meanwhile; reload it")
        let app = StandInShareDesk()
        app.standingAnswers = [moved]
        app.resourcePages = [ShareSecretSample.resources(), nil]
        let answer = await app.answer(share)
        #expect(answer == .refused("The hub refused the standing, and the app could not read the fleet's resources "
                                   + "after it, so the standing was not written. The owner's signed pool statement is "
                                   + "in the vault, and while it stands with no standing the central vault can send the "
                                   + "value to the server of each worker or lead that the fleet's list gives the secret "
                                   + "to. Call share_secret again in the same way; call it with max null only if the "
                                   + "owner no longer wants the standing. The hub's words (status 409): team.json "
                                   + "changed meanwhile; reload it"))
        #expect(app.asked == checks + ["sign pool", "standing use \(base)", "resources"])
        #expect(app.standings.count == 1 && app.unpools == 0 && app.refreshes == 0)
    }

    /// **A 409 of a standing whose base did not move** (point 3: a generation that changed, or a checkout that cannot
    /// take the commit): a certain refusal, decided by the read after it alone. No second send.
    @Test func aStandingWhose409LeftTheBaseAsItWasIsARefusal() async {
        let broken = SaveBotToken.HubFailure.refused(409, "the hub checkout has local changes")
        // No standing in that read: the signed end goes.
        let none = StandInShareDesk()
        none.standingAnswers = [broken]
        let taken = await none.answer(share)
        #expect(taken == .refused(GrantSecret.withHubWords(ShareSecret.standingRefusedTakenBack, status: 409,
                                                           "the hub checkout has local changes")))
        #expect(none.asked == checks + ["sign pool", "standing use \(base)", "resources", "sign unpool"])
        #expect(none.standings.count == 1 && none.unpools == 1)
        // A standing there: no signed end, and no second send.
        let held = StandInShareDesk()
        held.standingAnswers = [broken]
        held.resourcePages = [ShareSecretSample.resources(), ShareSecretSample.resources(standing: [key])]
        let kept = await held.answer(share)
        #expect(kept == .refused(GrantSecret.withHubWords(ShareSecret.standingRefusedHubHasOne, status: 409,
                                                          "the hub checkout has local changes")))
        #expect(held.asked == checks + ["sign pool", "standing use \(base)", "resources"])
        #expect(held.standings.count == 1 && held.unpools == 0)
    }

    /// **A 409 of a standing whose base moved while this secret's standing stayed as it was** (point 4): one more
    /// send with the base of the read after it, and the decision by that second answer: taken is the answer of a
    /// call that went; not known is "not known"; a certain refusal, a second 409 among them, is decided by one more
    /// read.
    @Test func aStandingWhoseBaseMovedIsSentOnceMore() async throws {
        let moved = SaveBotToken.HubFailure.refused(409, "team.json changed meanwhile; reload it")
        let toTheConflict = checks + ["sign pool", "standing use \(base)", "resources"]
        // The same standing in both reads, at the same level: one more send.
        let same = StandInShareDesk()
        same.standingAnswers = [moved, nil]
        same.resourcePages = [ShareSecretSample.resources(standing: [key], level: "read"),
                              ShareSecretSample.resources(base: newer, standing: [key], level: "read")]
        _ = try await same.went(share)
        #expect(same.asked == toTheConflict + ["standing use \(newer)", "refresh"])
        // The second send is taken.
        for changed in [true, false] {
            let app = StandInShareDesk()
            app.standingAnswers = [moved, nil]
            app.changed = [changed]
            app.resourcePages = [ShareSecretSample.resources(), ShareSecretSample.resources(base: newer)]
            let answer = try await app.went(share)
            #expect(app.asked == toTheConflict + ["standing use \(newer)", "refresh"])
            #expect(app.standings == ["\(base) \(key) use", "\(newer) \(key) use"])
            #expect(answer["changed"] == JSONValue.bool(changed) && answer["signed"] == JSONValue.bool(true))
            #expect(app.statements.count == 1 && app.unpools == 0)
        }
        // The second send is not known.
        for failure in GrantSecretSample.notKnown {
            let app = StandInShareDesk()
            app.standingAnswers = [moved, failure]
            app.resourcePages = [ShareSecretSample.resources(), ShareSecretSample.resources(base: newer)]
            let answer = await app.answer(share)
            #expect(answer == .refused(ShareSecret.standingNotKnown), "\(failure)")
            #expect(app.asked == toTheConflict + ["standing use \(newer)"], "\(failure)")
            #expect(app.unpools == 0 && app.refreshes == 0, "\(failure)")
        }
        // The second send is refused, a second 409 among them: one more read decides, and with no standing there the
        // signed end goes.
        for second in [SaveBotToken.HubFailure.refused(409, "again"), SaveBotToken.HubFailure.refused(400, "no")] {
            let app = StandInShareDesk()
            app.standingAnswers = [moved, second]
            app.resourcePages = [ShareSecretSample.resources(), ShareSecretSample.resources(base: newer)]
            let answer = await app.answer(share)
            guard case .refused(let status, let said) = second else { continue }
            #expect(answer == .refused(GrantSecret.withHubWords(ShareSecret.standingRefusedTakenBack, status: status,
                                                                said)))
            #expect(app.asked == toTheConflict + ["standing use \(newer)", "resources", "sign unpool"])
            #expect(app.unpools == 1 && app.standings.count == 2)
        }
        // A second 409, and the read after it shows a standing: no signed end.
        let has = StandInShareDesk()
        has.standingAnswers = [moved, moved]
        has.resourcePages = [ShareSecretSample.resources(), ShareSecretSample.resources(base: newer),
                             ShareSecretSample.resources(base: newer, standing: [key])]
        let kept = await has.answer(share)
        #expect(kept == .refused(GrantSecret.withHubWords(ShareSecret.standingRefusedHubHasOne, status: 409,
                                                          "team.json changed meanwhile; reload it")))
        #expect(has.asked == toTheConflict + ["standing use \(newer)", "resources"] && has.unpools == 0)
        // A second refusal whose read after it fails: no signed end.
        let unread = StandInShareDesk()
        unread.standingAnswers = [moved, SaveBotToken.HubFailure.refused(400, "no")]
        unread.resourcePages = [ShareSecretSample.resources(), ShareSecretSample.resources(base: newer), nil]
        let lost = await unread.answer(share)
        #expect(lost == .refused(GrantSecret.withHubWords(ShareSecret.standingRefusedUnread, status: 400, "no")))
        #expect(unread.asked == toTheConflict + ["standing use \(newer)", "resources"] && unread.unpools == 0)
    }

    /// **A 409 of a standing whose base moved with this secret's standing** (point 5): the owner's own control can
    /// have changed it while the call ran, and a second send would undo that. No second send: the read after the 409
    /// decides, as after a certain refusal, with words that say first that the standing changed.
    @Test func aStandingWhoseStandingChangedWhileTheCallRanIsNotSentAgain() async {
        let moved = SaveBotToken.HubFailure.refused(409, "team.json changed meanwhile; reload it")
        let words = "team.json changed meanwhile; reload it"
        let toTheConflict = checks + ["sign pool", "standing use \(base)", "resources"]
        // None at the first read, one now (the owner's own "Who may give it"): no signed end.
        let came = StandInShareDesk()
        came.standingAnswers = [moved]
        came.resourcePages = [ShareSecretSample.resources(),
                              ShareSecretSample.resources(base: newer, standing: [key], level: "read")]
        let kept = await came.answer(share)
        #expect(kept == .refused("The hub's standing for this secret changed while this call ran, so the app did not "
                                 + "send its standing again. The hub refused this call. The hub has a standing for this "
                                 + "secret, which stays as it is, and the owner's signed pool statement stands for it. "
                                 + "Before any further call of share_secret for this secret, read "
                                 + "fleet_read(page=\"resources\") and ask the owner which standing they want. "
                                 + "The hub's words (status 409): " + words))
        #expect(came.asked == toTheConflict && came.standings.count == 1 && came.unpools == 0)
        // One at the first read, none now (the owner's own "Only you give it"): the signed end goes.
        let went = StandInShareDesk()
        went.standingAnswers = [moved]
        went.resourcePages = [ShareSecretSample.resources(standing: [key]), ShareSecretSample.resources(base: newer)]
        let ended = await went.answer(share)
        #expect(ended == .refused(GrantSecret.withHubWords(ShareSecret.standingChanged + " "
                                                           + ShareSecret.standingRefusedTakenBack + " "
                                                           + ShareSecret.askOwnerFirst, status: 409, words)))
        #expect(went.asked == toTheConflict + ["sign unpool"] && went.standings.count == 1 && went.unpools == 1)
        // The same, and the signed end fails: a statement can stay.
        let left = StandInShareDesk()
        left.standingAnswers = [moved]
        left.signAnswers = [nil, SaveBotToken.HubFailure.noAnswer]
        left.resourcePages = [ShareSecretSample.resources(standing: [key]), ShareSecretSample.resources(base: newer)]
        let stays = await left.answer(share)
        // Not "ask the owner first" here: the sentence's own step ends only the statement that this call left, and a
        // standing after that end waits for the owner's word.
        #expect(stays == .refused(GrantSecret.withHubWords(ShareSecret.standingChanged + " "
                                                           + ShareSecret.standingRefusedStatementLeft + " "
                                                           + ShareSecret.askOwnerAfterEnd, status: 409, words)))
        #expect(left.asked == toTheConflict + ["sign unpool"])
        // Another level now: changed too, and no second send.
        let level = StandInShareDesk()
        level.standingAnswers = [moved]
        level.resourcePages = [ShareSecretSample.resources(standing: [key]),
                               ShareSecretSample.resources(base: newer, standing: [key], level: "read")]
        let other = await level.answer(share)
        #expect(other == .refused(GrantSecret.withHubWords(ShareSecret.standingChanged + " "
                                                           + ShareSecret.standingRefusedHubHasOne + " "
                                                           + ShareSecret.askOwnerFirst, status: 409, words)))
        #expect(level.asked == toTheConflict && level.standings.count == 1)
        // Another secret's standing changed, and this one's did not: one more send.
        let twin = StandInShareDesk()
        twin.standingAnswers = [moved, nil]
        twin.resourcePages = [ShareSecretSample.resources(),
                              ShareSecretSample.resources(base: newer, standing: [ShareSecretSample.twin])]
        let sent = await twin.result(share)
        #expect(sent?["signed"] == JSONValue.bool(true))
        #expect(twin.asked == toTheConflict + ["standing use \(newer)", "refresh"])
    }

    /// **A standing, the statement taken, then the hub's standing refused for certain.** The app reads the resources
    /// one time more and decides by that read alone. No standing for this secret there: the signed `unpool` goes,
    /// and the secret is out of the pool; when it fails, a signed pool statement can stay. A standing there, at any
    /// level: no `unpool`. A read that failed: no `unpool`.
    @Test func aStandingWhoseStandingTheHubRefuses() async {
        let hubs = "resource 'secret:bws://example': max must be one of use, read"
        let toTheRefusal = checks + ["sign pool", "standing use \(base)"]
        // The read after the refusal has no standing: the signed end, and the secret is out of the pool.
        for status in [400, 403, 404, 422, 499] {
            let app = StandInShareDesk()
            app.standingAnswers = [SaveBotToken.HubFailure.refused(status, hubs)]
            let answer = await app.answer(share)
            #expect(answer == .refused("The hub refused the standing, and the app took the owner's signed pool "
                                       + "statement back: the hub has no standing for this secret, and the secret is "
                                       + "out of the grantable pool. If the central vault sent the value to a server "
                                       + "while the statement stood, it takes it back from each server for which the "
                                       + "owner signed no grant of it, where that server's vault takes withdrawals, at "
                                       + "the first pass of the hub at which that server takes part (its vault reports "
                                       + "to the hub, and the owner's pin is its vault's key). The hub's words "
                                       + "(status \(status)): " + hubs),
                    "\(status)")
            #expect(app.asked == toTheRefusal + ["resources", "sign unpool"], "\(status)")
            #expect(app.statements.count == 2 && app.unpools == 1 && app.refreshes == 0, "\(status)")
            #expect(app.statements.last == ShareSecret.Statement(fleet: fleet, login: key, inPool: false))
        }
        // The signed end fails, in each way: a signed pool statement stays, and the words name the call that ends it.
        var failures = GrantSecretSample.notKnown
        failures.append(SaveBotToken.HubFailure.refused(400, "older"))
        failures.append(ShareSecret.NotSigned())
        for failure in failures {
            let app = StandInShareDesk()
            app.standingAnswers = [SaveBotToken.HubFailure.refused(400, hubs)]
            app.signAnswers = [nil, failure]
            let answer = await app.answer(share)
            #expect(answer == .refused(GrantSecret.withHubWords(ShareSecret.standingRefusedStatementLeft, status: 400,
                                                                hubs)), "\(failure)")
            #expect(app.asked == toTheRefusal + ["resources", "sign unpool"], "\(failure)")
        }
        // The read after the refusal has a standing for this secret: no signed end.
        let app = StandInShareDesk()
        app.standingAnswers = [SaveBotToken.HubFailure.refused(400, hubs)]
        app.resourcePages = [ShareSecretSample.resources(), ShareSecretSample.resources(standing: [key])]
        let answer = await app.answer(share)
        #expect(answer == .refused("The hub refused this call. The hub has a standing for this secret, which stays as "
                                   + "it is, and the owner's signed pool statement stands for it. The hub's words "
                                   + "(status 400): " + hubs))
        #expect(app.asked == toTheRefusal + ["resources"] && app.unpools == 0 && app.statements.count == 1)
        // The read after the refusal failed: no signed end, and the words say what can be left.
        let unread = StandInShareDesk()
        unread.standingAnswers = [SaveBotToken.HubFailure.refused(400, hubs)]
        unread.resourcePages = [ShareSecretSample.resources(), nil]
        let lost = await unread.answer(share)
        #expect(lost == .refused(GrantSecret.withHubWords(ShareSecret.standingRefusedUnread, status: 400, hubs)))
        #expect(unread.asked == toTheRefusal + ["resources"] && unread.unpools == 0 && unread.statements.count == 1)
    }

    /// **The read after the refusal decides alone, never the call's first read.** The first read had a standing and
    /// the second has none: the signed end goes. The first had none and the second has one (the owner's own control
    /// in the app, between the two): no signed end. A standing of another secret is no standing of this one.
    @Test func theReadAfterTheRefusalDecidesAlone() async {
        let refused = SaveBotToken.HubFailure.refused(400, "no")
        let toTheRefusal = checks + ["sign pool", "standing read \(base)"]
        let takenBack = OwnerChannel.Answer.refused(GrantSecret.withHubWords(ShareSecret.standingRefusedTakenBack,
                                                                             status: 400, "no"))
        let had = StandInShareDesk()
        had.standingAnswers = [refused]
        had.resourcePages = [ShareSecretSample.resources(standing: [key]), ShareSecretSample.resources()]
        #expect(await had.answer(read) == takenBack)
        #expect(had.asked == toTheRefusal + ["resources", "sign unpool"])
        let came = StandInShareDesk()
        came.standingAnswers = [refused]
        came.resourcePages = [ShareSecretSample.resources(), ShareSecretSample.resources(standing: [key])]
        let second = await came.answer(read)
        #expect(second == .refused(GrantSecret.withHubWords(ShareSecret.standingRefusedHubHasOne, status: 400, "no")))
        #expect(came.asked == toTheRefusal + ["resources"] && came.statements.count == 1)
        // The twin's standing is no standing of this secret: the signed end goes.
        let others = StandInShareDesk()
        others.standingAnswers = [refused]
        others.resourcePages = [ShareSecretSample.resources(),
                                ShareSecretSample.resources(standing: [ShareSecretSample.twin])]
        #expect(await others.answer(read) == takenBack)
        #expect(others.asked == toTheRefusal + ["resources", "sign unpool"])
        // The secret left the resources between the two reads: no standing of it is there, so the signed end goes.
        let gone = StandInShareDesk()
        gone.standingAnswers = [refused]
        gone.resourcePages = [ShareSecretSample.resources(),
                              ShareSecretSample.resources(without: [ShareSecretSample.key])]
        #expect(await gone.answer(read) == takenBack)
        #expect(gone.statements.count == 2 && gone.unpools == 1)
    }

    /// **A standing, the statement taken, then the hub's standing with no known outcome**: the app signed, whether
    /// the hub wrote the standing is not known, and the app reads nothing more and ends no statement.
    @Test func aStandingWhoseStandingIsNotKnown() async {
        for failure in GrantSecretSample.notKnown {
            let app = StandInShareDesk()
            app.standingAnswers = [failure]
            let answer = await app.answer(share)
            #expect(answer == .refused(ShareSecret.standingNotKnown), "\(failure)")
            #expect(app.asked == checks + ["sign pool", "standing use \(base)"], "\(failure)")
            #expect(app.statements.count == 1 && app.unpools == 0 && app.refreshes == 0, "\(failure)")
        }
    }

    /// **A take-back.** The hub's end refused for certain: nothing was changed, with the hub's words, and no signed
    /// end goes. Not known: the same call again. A 409 goes by the read after it (points 2 to 5): a read that failed,
    /// a base that did not move and a standing that changed end the call with nothing changed, and only a base that
    /// moved with this secret's standing as it was gets one more send. The hub's end taken and the signed end failed,
    /// in either way: the hub has no standing, a statement can stay, and the same call again ends it.
    @Test func aTakeBackWhoseWritesFail() async throws {
        let certain: [(Int, String)] = [(400, "resource must be <kind>:<what>"), (403, "not the owner"),
                                        (404, "not found")]
        for (status, said) in certain {
            let app = StandInShareDesk()
            app.standingAnswers = [SaveBotToken.HubFailure.refused(status, said)]
            let answer = await app.answer(takeBack)
            #expect(answer == .refused("The hub refused the end of the standing, so nothing was changed. The hub's "
                                       + "words (status \(status)): \(said)"))
            #expect(app.asked == checks + ["standing null \(base)"] && app.statements.isEmpty && app.refreshes == 0)
        }
        for failure in GrantSecretSample.notKnown {
            let app = StandInShareDesk()
            app.standingAnswers = [failure]
            let answer = await app.answer(takeBack)
            #expect(answer == .refused(ShareSecret.endNotKnown), "\(failure)")
            #expect(app.asked == checks + ["standing null \(base)"] && app.statements.isEmpty, "\(failure)")
        }
        // A 409, the base moved and this secret's standing as it was (point 4): one more read, one more send with its
        // base, and then the signed end.
        let moved = SaveBotToken.HubFailure.refused(409, "team.json changed meanwhile; reload it")
        let words = "team.json changed meanwhile; reload it"
        let toTheConflict = checks + ["standing null \(base)", "resources"]
        let again = StandInShareDesk()
        again.standingAnswers = [moved, nil]
        again.resourcePages = [ShareSecretSample.resources(standing: [key]),
                               ShareSecretSample.resources(base: newer, standing: [key])]
        let went = try await again.went(takeBack)
        #expect(went["changed"] == JSONValue.bool(true) && went["note"] == JSONValue.string(ShareSecret.noteTakenBack))
        #expect(again.asked == toTheConflict + ["standing null \(newer)", "sign unpool", "refresh"])
        // The read after the 409 fails (point 2): nothing was changed, with the words of the 409, and no signed end.
        let unread = StandInShareDesk()
        unread.standingAnswers = [moved]
        unread.resourcePages = [ShareSecretSample.resources(), nil]
        #expect(await unread.answer(takeBack) == .refused("The hub refused the end of the standing, and the app could "
                                                          + "not read the fleet's resources after it. This call changed "
                                                          + "nothing: it did not change the hub's standing, and it did "
                                                          + "not touch the owner's signed pool statement. Call "
                                                          + "share_secret again. The hub's words (status 409): " + words))
        #expect(unread.asked == toTheConflict && unread.statements.isEmpty && unread.refreshes == 0)
        // The base did not move (point 3): a certain refusal, with no second send.
        let broken = StandInShareDesk()
        broken.standingAnswers = [SaveBotToken.HubFailure.refused(409, "the hub checkout has local changes")]
        #expect(await broken.answer(takeBack) == .refused(GrantSecret.withHubWords(
            ShareSecret.endRefused, status: 409, "the hub checkout has local changes")))
        #expect(broken.asked == toTheConflict && broken.statements.isEmpty && broken.standings.count == 1)
        // This secret's standing changed while the call ran to another level (point 5): no second send, and the
        // owner decides.
        let changed = StandInShareDesk()
        changed.standingAnswers = [moved]
        changed.resourcePages = [ShareSecretSample.resources(standing: [key]),
                                 ShareSecretSample.resources(base: newer, standing: [key], level: "read")]
        #expect(await changed.answer(takeBack) == .refused("The hub's standing for this secret changed while this call "
                                                           + "ran, so the app sent no end of it again: this call changed "
                                                           + "nothing, and it did not touch the owner's signed pool "
                                                           + "statement. Read fleet_read(page=\"resources\") and ask the "
                                                           + "owner which standing they want. The hub's words (status "
                                                           + "409): " + words))
        #expect(changed.asked == toTheConflict && changed.statements.isEmpty && changed.standings.count == 1)
        // This secret's standing ended while the call ran (another writer, such as share_resource with no max, which
        // leaves the pool statement): what the call asks of the hub holds, so no second send, and the signed end goes,
        // as for a call that found no standing.
        let ended = StandInShareDesk()
        ended.standingAnswers = [moved]
        ended.resourcePages = [ShareSecretSample.resources(standing: [key]), ShareSecretSample.resources(base: newer)]
        let closed = try await ended.went(takeBack)
        #expect(closed["changed"] == JSONValue.bool(false)
                && closed["note"] == JSONValue.string(ShareSecret.noteEndedMeanwhile))
        #expect(ended.asked == toTheConflict + ["sign unpool", "refresh"] && ended.standings.count == 1)
        #expect(ended.unpools == 1)
        // A second 409: nothing was changed, with its words.
        let twice = StandInShareDesk()
        twice.standingAnswers = [moved, SaveBotToken.HubFailure.refused(409, "again")]
        twice.resourcePages = [ShareSecretSample.resources(), ShareSecretSample.resources(base: newer)]
        #expect(await twice.answer(takeBack) == .refused(GrantSecret.withHubWords(ShareSecret.endMoved, status: 409,
                                                                                  "again")))
        #expect(twice.asked == toTheConflict + ["standing null \(newer)"] && twice.statements.isEmpty)
        // Another refusal of the second send, and one with no known outcome.
        let other = StandInShareDesk()
        other.standingAnswers = [moved, SaveBotToken.HubFailure.refused(400, "no")]
        other.resourcePages = [ShareSecretSample.resources(), ShareSecretSample.resources(base: newer)]
        #expect(await other.answer(takeBack) == .refused(GrantSecret.withHubWords(ShareSecret.endRefused, status: 400,
                                                                                  "no")))
        #expect(other.statements.isEmpty)
        let lost = StandInShareDesk()
        lost.standingAnswers = [moved, SaveBotToken.HubFailure.noAnswer]
        lost.resourcePages = [ShareSecretSample.resources(), ShareSecretSample.resources(base: newer)]
        #expect(await lost.answer(takeBack) == .refused(ShareSecret.endNotKnown))
        #expect(lost.statements.isEmpty)
        // The hub's end taken, and the signed end fails: the standing is ended, and the statement stays.
        var failures = GrantSecretSample.notKnown
        failures.append(ShareSecret.NotSigned())
        for failure in failures {
            let app = StandInShareDesk()
            app.signAnswers = [failure]
            let answer = await app.answer(takeBack)
            #expect(answer == .refused(ShareSecret.unpoolFailed), "\(failure)")
            #expect(app.asked == checks + ["standing null \(base)", "sign unpool", "refresh"], "\(failure)")
        }
        let app = StandInShareDesk()
        app.signAnswers = [SaveBotToken.HubFailure.refused(400, "the statement is older")]
        let answer = await app.answer(takeBack)
        #expect(answer == .refused(ShareSecret.unpoolFailed + " The hub's words (status 400): the statement is older"))
        #expect(app.refreshes == 1)
        // The same call again: the hub's end is no change, and the end of the statement is sent again.
        app.signAnswers = [nil]
        app.changed = [false]
        let next = await app.result(takeBack)
        #expect(next?["note"] == JSONValue.string(ShareSecret.noteNoStanding))
        #expect(app.statements.count == 2 && app.standings.count == 2 && app.unpools == 2)
    }

    /// **The signed `unpool` of a standing goes only in its one case**: after a certain refusal of the hub's
    /// standing whose later read shows no standing. A 409 is a certain refusal when the base did not move, when this
    /// secret's standing moved with it, and when a second send got one more. Every other end of a standing signs one
    /// statement or none.
    @Test func theUnpoolOfAStandingIsSignedOnlyInItsOneCase() async {
        let refused = SaveBotToken.HubFailure.refused(400, "no"), moved = SaveBotToken.HubFailure.refused(409, "moved")
        let fault = SaveBotToken.HubFailure.refused(500, "no"), lost = SaveBotToken.HubFailure.noAnswer
        let key = ShareSecretSample.key, newer = ShareSecretSample.newer
        let plain = ShareSecretSample.resources(), held = ShareSecretSample.resources(standing: [key])
        let movedPlain = ShareSecretSample.resources(base: newer)
        let movedHeld = ShareSecretSample.resources(base: newer, standing: [key])
        let cases: [(String, (StandInShareDesk) -> Void)] = [
            ("a standing that goes", { _ in }),
            ("a statement refused", { $0.signAnswers = [SaveBotToken.HubFailure.refused(409, "no")] }),
            ("a statement not known", { $0.signAnswers = [lost] }),
            ("a standing not known", { $0.standingAnswers = [lost] }),
            ("a standing refused with a fault of the hub", { $0.standingAnswers = [fault] }),
            ("a standing refused, a standing in the hub", {
                $0.standingAnswers = [refused]; $0.resourcePages = [plain, held]
            }),
            ("a standing refused, the resources not read", {
                $0.standingAnswers = [refused]; $0.resourcePages = [plain, nil]
            }),
            ("a 409, the resources not read", { $0.standingAnswers = [moved]; $0.resourcePages = [plain, nil] }),
            ("a 409 with the base as it was, a standing in the hub", {
                $0.standingAnswers = [moved]; $0.resourcePages = [plain, held]
            }),
            ("a 409 with the base as it was, no standing in the hub", { $0.standingAnswers = [moved] }),
            ("a 409, the base moved, then taken", {
                $0.standingAnswers = [moved, nil]; $0.resourcePages = [plain, movedPlain]
            }),
            ("a 409, the standing changed, one now", {
                $0.standingAnswers = [moved]; $0.resourcePages = [plain, movedHeld]
            }),
            ("a 409, the standing changed, none now", {
                $0.standingAnswers = [moved]; $0.resourcePages = [held, movedPlain]
            }),
            ("a standing refused, no standing in the hub", { $0.standingAnswers = [refused] }),
            ("a second 409, no standing in the hub", {
                $0.standingAnswers = [moved, moved]; $0.resourcePages = [plain, movedPlain]
            }),
        ]
        var signed: [String] = []
        for (name, change) in cases {
            let app = StandInShareDesk()
            change(app)
            _ = await app.answer(share)
            #expect(app.statements.count - app.unpools <= 1 && app.unpools <= 1, "\(name)")
            if app.unpools > 0 { signed.append(name) }
        }
        #expect(signed == ["a 409 with the base as it was, no standing in the hub",
                           "a 409, the standing changed, none now", "a standing refused, no standing in the hub",
                           "a second 409, no standing in the hub"])
    }

    /// **No refusal of the app quotes what the caller sent**: the marker as a level, as a field's name and in a
    /// reference is in no refusal, before a write and after one. A reference of the list is in none either.
    @Test func noRefusalOfTheAppQuotesWhatTheCallerSent() async {
        let app = StandInShareDesk()
        let calls: [[String: JSONValue]] = [
            ShareSecretSample.with(["max": .string(marker)]),
            ShareSecretSample.with([marker: .string(marker)]),
            ShareSecretSample.with(["login": .string("bws://" + marker)]),
            ShareSecretSample.with(["login": .array([.string(marker)])]),
            ShareSecretSample.with(["to": .string(marker)]),
        ]
        var said: [String] = []
        for fields in calls {
            if let words = await app.refusal(fields) { said.append(words) }
        }
        #expect(said.count == 5 && said.allSatisfy { !$0.contains(marker) && !$0.contains("zq") })
        #expect(app.writes == 0)
        let lost = SaveBotToken.HubFailure.noAnswer
        let failing: [(signs: [(any Error)?], standings: [(any Error)?])] = [
            ([lost], [nil]), ([nil], [lost]),
            ([nil, lost], [SaveBotToken.HubFailure.refused(400, "refused by the hub")]),
        ]
        for failure in failing {
            for fields in [ShareSecretSample.share, ShareSecretSample.takeBack] {
                let other = StandInShareDesk()
                other.signAnswers = failure.signs
                other.standingAnswers = failure.standings
                let words = await other.refusal(fields)
                #expect(words != nil && words?.contains(ShareSecretSample.key) == false, "\(words ?? "")")
            }
        }
    }
}

// ------------------------------------------------------------ the program

/// **The program's side of `share_secret`**, with a stand-in link: what one call sends, that a wrong field reaches no
/// link, and what the program says when its answer is lost.
final class OwnerShareSecretProgramTests {
    let home = Fixture.home()
    deinit { try? FileManager.default.removeItem(at: home) }

    static let answered = JSONValue.object(["login": .string(ShareSecretSample.key), "max": .string("use"),
                                            "to": .string("workers"), "signed": .bool(true),
                                            "changed": .bool(true), "note": .string(ShareSecret.noteDelivery)])

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

    /// **The tool is a write of the program alone, and the last one of its list but one** (`answer_secret_request`
    /// came after it): taken by `write` and by the MCP form, refused by `call`, and no tool of `owner_mcp.py`'s table.
    @Test func theToolIsAWriteOfTheProgramAloneAndTheLastOne() throws {
        let tools = OwnerTools(table: Fixture.table, context: context(ValueLink()))
        let tool = try #require(tools.listed.first { $0.name == ShareSecret.name })
        #expect(tool.annotations == .object(["readOnlyHint": .bool(false)]))
        #expect(OwnerTools.verb(of: tool) == .write)
        #expect(tools.listed.suffix(2).map(\.name) == [ShareSecret.name, AnswerSecret.name])
        #expect(Fixture.table.tool(ShareSecret.name) == nil)
        let (status, out, _) = try run(["tools"], ValueLink())
        #expect(status == 0)
        #expect(out.dropLast().last == "write share_secret: " + ShareSecret.tool.firstSentence)
        #expect(out.filter { $0.hasPrefix("write share_secret") }.count == 1)
        let (one, full, _) = try run(["tools", "share_secret"], ValueLink())
        #expect(one == 0 && full.contains(ShareSecret.tool.description))
        #expect(full.contains("From a shell: founderizer-cli write share_secret '<json object>'"))
    }

    /// **`write` sends the two fields and no value part, and reads nothing on this Mac**: a standing at each level,
    /// and a take-back with `max` as a JSON null. `call` refuses the tool, because it is a write.
    @Test func writeSendsTheTwoFieldsAndNoValuePart() throws {
        let looked = LookedInput()
        let link = ValueLink(.answer(.result(Self.answered)))
        let calls = [ShareSecretSample.share, ShareSecretSample.read, ShareSecretSample.takeBack]
        for (number, fields) in calls.enumerated() {
            let (status, out, said) = try run(["write", "share_secret", JSONValue.object(fields).dumps()], link,
                                              input: looked.input)
            #expect(status == 0 && said.isEmpty && JSONValue.parse(out.joined()) == Self.answered)
            #expect(link.all.count == number + 1)
            #expect(link.all.last?.0 == OwnerChannel.Request(set: "owner", tool: "share_secret", fields: fields))
            #expect(link.all.last?.1 == nil && link.all.last?.0.valueBytes == nil)
        }
        // The take-back's null is on the wire as a null, and the app's read of the line has it.
        let line = try #require(link.all.last?.0.line)
        let read = try OwnerChannel.Request.read(Data(line.dropLast())).get()
        #expect(read.fields == ShareSecretSample.takeBack && read.fields["max"] == JSONValue.null)
        #expect(looked.count == 0)
        let (refused, _, words) = try run(["call", "share_secret", JSONValue.object(ShareSecretSample.share).dumps()],
                                          link)
        #expect(refused == 1 && words == ["share_secret writes, so founderizer-cli call does not take it: run "
                                          + "founderizer-cli write share_secret '<json object>'. The owner's client "
                                          + "asks before each write."])
        #expect(link.all.count == 3)
    }

    /// **A call with a wrong field reaches no link**: each refusal of the fields is the program's own, in the tool's
    /// fixed sentence, and nothing is sent.
    @Test func aWrongFieldReachesNoLink() throws {
        let key = ShareSecretSample.key
        let share = ShareSecretSample.share
        let cases: [([String: JSONValue], String)] = [
            ([:], ShareSecret.loginWord),
            (share.filter { $0.key != "max" }, ShareSecret.needsMax),
            (share.merging(["max": .string("write")]) { $1 }, ShareSecret.maxWord),
            (share.merging(["max": .bool(false)]) { $1 }, ShareSecret.maxWord),
            (share.merging(["login": .string("secret:" + key)]) { $1 }, ShareSecret.loginWord),
            (share.merging(["login": .string(key.uppercased())]) { $1 }, ShareSecret.loginWord),
            (share.merging(["to": .string("workers")]) { $1 }, ShareSecret.only),
            (share.merging(["request_id": .string("x")]) { $1 }, ShareSecret.only),
            (share.merging(["value": .string("x")]) { $1 }, OwnerLinkTools.neverAField),
            (["resource": .string("secret:" + key), "max": .string("use")], ShareSecret.only),
        ]
        for (fields, words) in cases {
            let link = ValueLink(.answer(.result(Self.answered)))
            let (status, _, said) = try run(["write", "share_secret", JSONValue.object(fields).dumps()], link)
            #expect(status == 1 && link.all.isEmpty, "\(fields)")
            #expect(said == [words], "\(fields)")
        }
        let link = ValueLink()
        let tools = OwnerTools(table: Fixture.table, context: context(link))
        #expect(tools.call("share_secret", .array([])) == ("share_secret takes one JSON object of its fields. Nothing "
                                                           + "was sent.", true))
        #expect(tools.call("share_secret", nil) == (ShareSecret.loginWord, true))
        #expect(link.all.isEmpty)
    }

    /// **The MCP form lists the tool and takes it**, with a null `max` as a take-back, and reads nothing of its
    /// standard input.
    @Test func theMCPFormListsItAndTakesANullMax() throws {
        let looked = LookedInput()
        let link = ValueLink(.answer(.result(Self.answered)))
        let lines = Lines()
        let mcp = OwnerMCP(tools: OwnerTools(table: Fixture.table, context: context(link, input: looked.input)),
                           version: "0.1.0", sink: { lines.add($0) })
        mcp.take(line: #"{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}"#)
        let calls = [ShareSecretSample.takeBack, ShareSecretSample.share.filter { $0.key != "max" }]
        for (number, fields) in calls.enumerated() {
            mcp.take(line: JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .int(Int64(number + 2)), "method": .string("tools/call"),
                "params": .object(["name": .string("share_secret"), "arguments": .object(fields)]),
            ]).dumps())
        }
        mcp.finish()
        let said = lines.wait(for: 3)
        let listed = try #require(said.first { $0["id"] == .int(1) }?["result"]?["tools"]?.array)
        let tool = try #require(listed.dropLast().last)
        #expect(tool["name"] == .string("share_secret"))
        #expect(tool["annotations"]?["readOnlyHint"] == .bool(false))
        #expect(tool["inputSchema"]?["required"] == .array([.string("login"), .string("max")]))
        let taken = try #require(said.first { $0["id"] == .int(2) }?["result"])
        #expect(taken["isError"] == .bool(false))
        #expect(link.all.count == 1 && link.all.first?.0.fields == ShareSecretSample.takeBack)
        // A call with no max is refused in the program, and no second request goes.
        let missing = try #require(said.first { $0["id"] == .int(3) }?["result"])
        #expect(missing["isError"] == .bool(true))
        #expect(missing["content"]?.array?.first?["text"] == .string(ShareSecret.needsMax))
        #expect(looked.count == 0)
    }

    /// **A lost answer has this tool's own words**: what the app signed and wrote is not known, and the same call
    /// again is safe. An answer of the app goes back as it is, and a failure before the send keeps the link's words.
    @Test func aLostAnswerHasThisToolsOwnWords() {
        for words in [ChannelClient.noAnswer, ChannelClient.closedNoAnswer, ChannelClient.unreadable] {
            let link = ValueLink(.failed(words))
            let tools = OwnerTools(table: Fixture.table, context: context(link))
            for fields in [ShareSecretSample.share, ShareSecretSample.takeBack] {
                #expect(tools.call("share_secret", .object(fields)) == (ShareSecret.notKnownHere, true))
            }
            #expect(link.all.count == 2)
        }
        for refusal in [ShareSecret.busy, ShareSecret.standingNotKnown, ShareSecret.unpoolFailed] {
            let tools = OwnerTools(table: Fixture.table, context: context(ValueLink(.answer(.refused(refusal)))))
            #expect(tools.call("share_secret", .object(ShareSecretSample.share)) == (refusal, true))
        }
        let took = OwnerTools(table: Fixture.table, context: context(ValueLink(.answer(.result(Self.answered)))))
        #expect(took.call("share_secret", .object(ShareSecretSample.share)) == (Self.answered.dumps(indent: 1), false))
        let notRunning = OwnerTools(table: Fixture.table, context: context(ValueLink(.nothingListens)))
        #expect(notRunning.call("share_secret", .object(ShareSecretSample.share)) == (AppLink.notStarted, true))
    }
}

// ------------------------------------------------------------ the whole way

/// **The whole way**: the program's tool, the real exchange on a socket of the test's own, the board as
/// `LinkTools.add` fills it (the set `owner`, no value part, one line of writes of the tool's own), and the tool's
/// logic with a stand-in desk.
final class OwnerShareSecretLinkTests {
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

    private func wired() async -> (board: SetupBoard, desk: StandInShareDesk, ends: CallEnds) {
        await MainActor.run {
            let app = StandInShareDesk()
            let ends = CallEnds()
            let board = SetupBoard(read: { OwnerSetupBoardTests.facts() }, show: { _, _ in nil })
            let desk = app.desk, line = app.line
            let added = board.add(set: OwnerSetupTools.set, tool: ShareSecret.name, value: .none) { fields, value in
                let answer = await ShareSecret.answer(fields: fields, value: value, desk: desk, line: line)
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

    /// **A standing and a take-back go the whole way**: the program checks the fields and sends them with no value
    /// part, the app checks them again, signs and writes, and the answer comes back as the app made it. A refusal of
    /// the app comes back in its words, and a wrong field never reaches the app.
    @Test func aStandingAndATakeBackGoTheWholeWay() async throws {
        let (board, app, _) = await wired()
        let link = listener(board)
        defer { link.stop() }
        #expect(link.start() == .listening)
        let tools = tools()
        let (text, isError) = await off { tools.call("share_secret", .object(ShareSecretSample.share)) }
        #expect(!isError, "\(text)")
        let note = [ShareSecret.noteUse, ShareSecret.noteTold, ShareSecret.noteDelivery].joined(separator: " ")
        let expected: JSONValue = .object([
            "login": .string(ShareSecretSample.key), "max": .string("use"), "to": .string("workers"),
            "signed": .bool(true), "changed": .bool(true), "note": .string(note),
        ])
        #expect(JSONValue.parse(text) == expected)
        var asked = await MainActor.run { app.asked }
        #expect(asked == ShareSecretSample.checks + ["sign pool", "standing use \(ShareSecretSample.base)", "refresh"])
        // A take-back: the null crosses the link as a null.
        let (back, backFailed) = await off { tools.call("share_secret", .object(ShareSecretSample.takeBack)) }
        #expect(!backFailed, "\(back)")
        let taken = try #require(JSONValue.parse(back)?.object)
        #expect(taken["max"] == JSONValue.null && taken["signed"] == JSONValue.bool(true) && taken["to"] == nil)
        asked = await MainActor.run { app.asked }
        #expect(Array(asked.suffix(3)) == ["standing null \(ShareSecretSample.base)", "sign unpool", "refresh"])
        // A refusal of the app, the whole way.
        let (refused, failed) = await off {
            tools.call("share_secret", .object(ShareSecretSample.with(["login": .string(ShareSecretSample.password),
                                                                      "max": .string("read")])))
        }
        #expect(failed && refused == ShareSecret.readNeedsKey)
        // A wrong field never reaches the app.
        let before = await MainActor.run { app.asked.count }
        let (wrong, wrongFailed) = await off {
            tools.call("share_secret", .object(ShareSecretSample.share.filter { $0.key != "max" }))
        }
        #expect(wrongFailed && wrong == ShareSecret.needsMax)
        let after = await MainActor.run { app.asked.count }
        #expect(after == before)
        // The board takes no value part for this tool: a raw request with one is refused before the tool runs.
        let path = path
        let part = await off {
            ChannelClient.exchange(path: path, request: .init(set: "owner", tool: ShareSecret.name,
                                                              fields: ShareSecretSample.share),
                                   value: OwnerChannel.Value(copying: Array("more".utf8)),
                                   check: StandInCheck(takes: true))
        }
        #expect(part == .answer(.refused("share_secret takes no value part after its request line, so the app did "
                                         + "nothing.")))
        let writes = await MainActor.run { app.writes }
        #expect(writes == 4)
    }

    /// **A client that goes after its line does not stop the second write.** The caller's connection ends while the
    /// first write of a standing waits: the listener frees its place and cancels the call's task. The write goes on,
    /// the hub's standing is still sent, one time, and no write saw a cancel.
    @Test func aClientThatGoesAfterItsLineDoesNotStopTheSecondWrite() async throws {
        let (board, app, ends) = await wired()
        await MainActor.run { app.holdAt = ["sign"] }
        let link = listener(board)
        defer { link.stop() }
        #expect(link.start() == .listening)
        // A client of its own: the request line, as the program sends it. It reads no answer.
        let request = OwnerChannel.Request(set: "owner", tool: ShareSecret.name, fields: ShareSecretSample.share)
        let socket = OwnerChannel.newSocket()
        try #require(socket >= 0)
        try #require(OwnerChannel.connect(socket, to: path) == 0)
        let wire = request.line
        #expect(wire.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) } == wire.count)
        // The first write stands at the hub, and nothing else was sent.
        #expect(await comes { app.holds("sign") == 1 })
        #expect(await MainActor.run { app.statements.count == 1 && app.standings.isEmpty })
        close(socket)
        // The listener saw the close and ended the connection: its place is free.
        #expect(await comes { link.openCount == 0 })
        // The writes stand where they stood: no cancel reached them, and the call did not end.
        #expect(await MainActor.run { app.holds("sign") == 1 && app.line.busy && ends.all.isEmpty })
        // Another caller meanwhile is refused, and sends nothing.
        let tools = tools()
        let (busy, failed) = await off { tools.call("share_secret", .object(ShareSecretSample.takeBack)) }
        #expect(failed && busy == ShareSecret.busy)
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
        #expect(answer["signed"] == .bool(true) && answer["to"] == .string("workers"))
        let seen = await MainActor.run { (asked: app.asked, standings: app.standings, steps: app.steps,
                                          busy: app.line.busy) }
        #expect(seen.standings == ["\(ShareSecretSample.base) \(ShareSecretSample.key) use"] && !seen.busy)
        // The writes of the first call, in their order; the checks of the refused call stand between them, and it
        // wrote nothing.
        let checks = ShareSecretSample.checks
        #expect(seen.asked == checks + ["sign pool"] + checks + ["standing use \(ShareSecretSample.base)", "refresh"])
        let writes = seen.steps.filter { ["sign", "standing"].contains($0.name) }
        #expect(writes.map(\.name) == ["sign", "standing"])
        #expect(writes.allSatisfy { !$0.cancelled }, "\(writes)")
        // The line is free: the next call writes.
        let (next, nextFailed) = await off { tools.call("share_secret", .object(ShareSecretSample.takeBack)) }
        #expect(!nextFailed, "\(next)")
    }
}
