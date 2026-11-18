import Foundation
import Testing
@testable import FleetCore
@testable import FleetOwnerAPI

// **A door card's signed press of `answer_needs_you`** (`OwnerAnswerDoor.swift`): which call the program sends to the
// app and which one to the hub, the app's answer to one request with a stand-in desk, and the words. The app's own
// desk (`LinkTools.doorDesk`) and its signature (`DoorCallSigning.maker`) are in the app target, which has no tests; the
// rules that the signature stands on are FleetCore's (`DoorCall`, `DoorCallTests`). No test reads a Keychain, signs
// anything or reaches a hub.

/// What the tests of the door's press share: an example item and an example request.
enum DoorPressSample {
    static let need = 31
    static let database = "g1"
    static let statement = #"{"at":1,"call":"c0ffee","fleet":"fleet-example","kind":"door-call","need":31,"v":1}"#
    static let signature = "c2lnbmVk"
    /// The door's card of a run on a server, open, and the card of a door call that names no server.
    static let runCard = AnswerDoor.Card(open: true, doorCall: true, host: "web-1")
    static let callCard = AnswerDoor.Card(open: true, doorCall: true)

    static func request(_ choice: Int64 = 0, need: Int = need) -> [String: JSONValue] {
        ["need": .int(Int64(need)), "choice": .int(choice), "db": .string(database)]
    }

    /// The door's card of a run as the hub's state has it (`hub.py` `need_view`), and a plain item.
    static func item(id: Int = need, answer: Any = NSNull(), chosen: Any = NSNull(), call: Any? = "c0ffee",
                     host: Any? = "web-1") -> JSONValue {
        var item: [String: Any] = ["id": id, "title": "Run one root script on web-1?", "answer": answer,
                                   "chosen": chosen, "options": ["Run it once", "Full access on web-1", "No"]]
        if let call { item["door_call"] = call }
        if let host { item["door_host"] = host }
        return JSONValue.parse(try! JSONSerialization.data(withJSONObject: item))!
    }
}

/// **The app's engine for the door's press as stand-ins**: the item as the app reads it, what the app's signature
/// gives, the hub's answer to the write, and a record of what the desk was asked, in its order. `Item` is the item's
/// id, so that a test sees which item the app signs.
@MainActor
final class StandInDoorDesk {
    struct Place: Sendable {}

    var ready = true
    var database = DoorPressSample.database
    /// What each read of the item gives, in the order of the reads: a reading, or nil for a read that fails. The last
    /// one serves each later read too.
    var items: [AnswerDoor.ItemRead<Int>?] = [.found(DoorPressSample.need, DoorPressSample.runCard)]
    var signed = AnswerDoor.Signed.signed(statement: DoorPressSample.statement, signature: DoorPressSample.signature)
    /// What the write gets: nil when it was taken.
    var sendAnswer: (any Error)?
    /// The step at which the call's task is cancelled, as the end of the call's connection does.
    var cancelAt: String?

    var asked: [String] = []
    var signedItems: [Int] = []
    var sent: [String] = []
    var refreshes = 0

    private func next(_ name: String) {
        asked.append(name)
        if cancelAt == name { withUnsafeCurrentTask { $0?.cancel() } }
    }

    var desk: AnswerDoor.Desk<Place, Int> {
        AnswerDoor.Desk<Place, Int>(
            ready: { [self] in
                next("ready")
                return ready ? Place() : nil
            },
            database: { [self] _ in database },
            item: { [self] _, need in
                next("item \(need)")
                let found = items.first ?? nil
                if items.count > 1 { items.removeFirst() }
                guard let found else { throw SaveBotToken.HubFailure.noAnswer }
                return found
            },
            sign: { [self] _, item, press in
                next("sign \(press.rawValue)")
                signedItems.append(item)
                return signed
            },
            send: { [self] _, need, press, statement, signature in
                next("send")
                sent.append("\(need) \(press.rawValue) \(statement) \(signature)")
                if let sendAnswer { throw sendAnswer }
            },
            refresh: { [self] in
                asked.append("refresh")
                refreshes += 1
            })
    }

    func answer(_ fields: [String: JSONValue], value: OwnerChannel.Value? = nil) async -> OwnerChannel.Answer {
        await AnswerDoor.answer(fields: fields, value: value, desk: desk)
    }

    /// The words of a call's refusal, or nil for a result.
    func refusal(_ fields: [String: JSONValue] = DoorPressSample.request()) async -> String? {
        if case .refused(let words) = await answer(fields) { return words }
        return nil
    }
}

// ------------------------------------------------------------ the app's answer

@MainActor
struct OwnerAnswerDoorAppTests {
    let checks = ["ready", "item 31", "sign 0"]

    /// **A press is signed by the app's own rule and sent once**: the app reads the item itself, signs the item that
    /// it read, and the one write carries that statement and its signature. The result says what was signed, and the
    /// card's server; a card that names no server gives none.
    @Test func aPressIsSignedAndSentOnce() async throws {
        let app = StandInDoorDesk()
        guard case .result(let answer) = await app.answer(DoorPressSample.request()) else {
            Issue.record("the press was refused")
            return
        }
        #expect(app.asked == checks + ["send", "refresh"] && app.signedItems == [31])
        #expect(app.sent == ["31 0 \(DoorPressSample.statement) \(DoorPressSample.signature)"])
        #expect(answer == .object(["need": .int(31), "choice": .int(0), "answered": .bool(true),
                                   "signed": .string("door-call"), "server": .string("web-1"),
                                   "note": .string(AnswerDoor.noteRunOnce)]))
        let full = StandInDoorDesk()
        guard case .result(let mode) = await full.answer(DoorPressSample.request(1)) else {
            Issue.record("Full access was refused")
            return
        }
        #expect(full.asked == ["ready", "item 31", "sign 1", "send", "refresh"])
        #expect(mode["signed"] == .string("door-mode") && mode["server"] == .string("web-1")
                && mode["note"] == .string(AnswerDoor.noteFullAccess))
        let call = StandInDoorDesk()
        call.items = [.found(31, DoorPressSample.callCard)]
        guard case .result(let once) = await call.answer(DoorPressSample.request()) else {
            Issue.record("Run it once of a card with no server was refused")
            return
        }
        #expect(once["server"] == nil && once["signed"] == .string("door-call"))
    }

    /// One refusal before the write: what the desk was asked up to it, and that nothing was sent.
    private func refused(_ words: String, asked: [String], fields: [String: JSONValue] = DoorPressSample.request(),
                         value: OwnerChannel.Value? = nil, _ change: (StandInDoorDesk) -> Void = { _ in }) async {
        let app = StandInDoorDesk()
        change(app)
        // In a task of its own, so that a cancel of the call's task is no cancel of the test's.
        let answer = await Task { @MainActor in await app.answer(fields, value: value) }.value
        #expect(answer == .refused(words), "\(words)")
        #expect(app.asked == asked, "\(words)")
        #expect(app.sent.isEmpty && app.refreshes == 0, "\(words)")
        #expect(words.hasSuffix(" Nothing was sent."), "\(words)")
    }

    /// **Each check refuses in its order, with its own sentence, and sends nothing**: the fields (only those that
    /// the program makes), the reading and its database, the item, the press of that item and its answer, and each
    /// reason of the app's own rule for signing nothing.
    @Test func eachCheckRefusesInItsOrderAndSendsNothing() async {
        let one = DoorPressSample.request()
        func with(_ more: [String: JSONValue]) -> [String: JSONValue] { one.merging(more) { $1 } }
        // The fields: the desk is never asked.
        await refused(AnswerDoor.noPart, asked: [], fields: one, value: OwnerChannel.Value(copying: Array("x".utf8)))
        await refused(OwnerLinkTools.neverAField, asked: [], fields: with(["key": .string("x")]))
        await refused(AnswerDoor.only, asked: [], fields: with(["answer": .string("Run it once")]))
        for need: JSONValue in [.string("31"), .int(0), .double(31), .bool(true), .int(2_147_483_648), .null] {
            await refused(AnswerDoor.needWord, asked: [], fields: with(["need": need]))
        }
        for choice: JSONValue in [.int(2), .int(-1), .string("0"), .double(0), .bool(false), .null] {
            await refused(AnswerDoor.choiceWord, asked: [], fields: with(["choice": choice]))
        }
        for db: JSONValue in [.string(""), .string(String(repeating: "g", count: 129)), .int(1), .null] {
            await refused(AnswerDoor.generationWord, asked: [], fields: with(["db": db]))
        }
        await refused(AnswerDoor.generationWord, asked: [], fields: one.filter { $0.key != "db" })
        // The reading, and the database that the program read.
        await refused(AnswerDoor.notReady, asked: ["ready"]) { $0.ready = false }
        await refused(AnswerDoor.otherFleet, asked: ["ready"]) { $0.database = "g2" }
        // The item.
        await refused(AnswerDoor.itemUnread, asked: ["ready", "item 31"]) { $0.items = [nil] }
        await refused(AnswerDoor.otherFleet, asked: ["ready", "item 31"]) { $0.items = [.otherGeneration] }
        await refused(AnswerDoor.noItem, asked: ["ready", "item 31"]) { $0.items = [AnswerDoor.ItemRead<Int>.none] }
        await refused(AnswerDoor.notDoorPress, asked: ["ready", "item 31"]) {
            $0.items = [.found(31, .init(open: true, doorCall: false, host: "web-1"))]
        }
        await refused(AnswerDoor.notDoorPress, asked: ["ready", "item 31"], fields: DoorPressSample.request(1)) {
            $0.items = [.found(31, DoorPressSample.callCard)]
        }
        await refused(AnswerDoor.answeredWithThis, asked: ["ready", "item 31"]) {
            $0.items = [.found(31, .init(open: false, chosen: 0, doorCall: true, host: "web-1"))]
        }
        for chosen: Int? in [1, 2, nil] {
            await refused(AnswerDoor.answeredAlready, asked: ["ready", "item 31"]) {
                $0.items = [.found(31, .init(open: false, chosen: chosen, doorCall: true, host: "web-1"))]
            }
        }
        // The app's own rule for signing, each "no" with its own sentence.
        let reasons: [(AnswerDoor.Signed, String)] = [
            (.moved, AnswerDoor.otherFleet), (.notOffered, AnswerDoor.notOffered),
            (.card(.otherHash), AnswerDoor.words(.otherHash)), (.vaultUnread, AnswerDoor.vaultUnread),
            (.noFleet, AnswerDoor.noFleet), (.noOwnerKey, AnswerDoor.noOwnerKey),
            (.notSignedNow, AnswerDoor.notSignedNow),
        ]
        for (signed, words) in reasons {
            await refused(words, asked: checks) { $0.signed = signed }
        }
        // A caller that went away before the write: nothing is sent.
        await refused(AnswerDoor.ended, asked: checks) { $0.cancelAt = "sign 0" }
    }

    /// **The hub's answer to the write.** A refusal because the item has its answer: one read more says whether that
    /// answer is this option. Every other certain refusal has the hub's words after the tool's sentence, and an
    /// outcome that is not known says so. No refresh follows a write that did not go.
    @Test func theHubsAnswerToTheWrite() async {
        let answered = AnswerDoor.ItemRead<Int>.found(31, .init(open: false, chosen: 0, doorCall: true, host: "web-1"))
        let other = AnswerDoor.ItemRead<Int>.found(31, .init(open: false, chosen: 2, doorCall: true, host: "web-1"))
        let open = AnswerDoor.ItemRead<Int>.found(31, DoorPressSample.runCard)
        let cases: [(AnswerDoor.ItemRead<Int>?, String)] = [
            (answered, AnswerDoor.hadAnswerWithThis), (other, AnswerDoor.answeredFirst),
            (open, AnswerDoor.answeredFirst), (nil, AnswerDoor.answeredFirst),
        ]
        for (again, words) in cases {
            let app = StandInDoorDesk()
            app.items = [open, again]
            app.sendAnswer = AnswerSecret.Answered()
            #expect(await app.refusal() == words)
            #expect(app.asked == checks + ["send", "item 31"] && app.refreshes == 0)
        }
        let refused = StandInDoorDesk()
        refused.sendAnswer = SaveBotToken.HubFailure.refused(400, "the door takes only a newer one: answer again")
        #expect(await refused.refusal() == GrantSecret.withHubWords(AnswerDoor.refused, status: 400,
                                                                    "the door takes only a newer one: answer again"))
        for error: any Error in [SaveBotToken.HubFailure.refused(500, "fault"), SaveBotToken.HubFailure.noAnswer,
                                 SaveBotToken.HubFailure.unreadable, CancellationError()] {
            let app = StandInDoorDesk()
            app.sendAnswer = error
            #expect(await app.refusal() == AnswerDoor.notKnown, "\(error)")
            #expect(app.sent.count == 1 && app.refreshes == 0)
        }
    }
}

// ------------------------------------------------------------ the words

struct OwnerAnswerDoorWordsTests {
    /// Each refusal before the write.
    static let before = [AnswerDoor.only, AnswerDoor.noPart, AnswerDoor.needWord, AnswerDoor.choiceWord,
                         AnswerDoor.generationWord, AnswerDoor.notReady, AnswerDoor.otherFleet, AnswerDoor.itemUnread,
                         AnswerDoor.noItem, AnswerDoor.notDoorPress, AnswerDoor.answeredWithThis,
                         AnswerDoor.answeredAlready, AnswerDoor.notOffered, AnswerDoor.vaultUnread,
                         AnswerDoor.noFleet, AnswerDoor.noOwnerKey, AnswerDoor.notSignedNow, AnswerDoor.ended]
        + [AnswerDoor.CardStop.olderHub, .noScript, .otherServer, .hidden("U+202E"), .padded, .decoy, .notShown,
           .otherHash].map(AnswerDoor.words)
    /// Each sentence after the write went out.
    static let after = [AnswerDoor.refused, AnswerDoor.hadAnswerWithThis, AnswerDoor.answeredFirst,
                        AnswerDoor.notKnown, AnswerDoor.notKnownHere]

    /// **"Nothing was sent." exactly when nothing was sent**, one line each.
    @Test func theSentencesSayNothingWasSentExactlyWhenNothingWas() {
        #expect(Set(Self.before).count == Self.before.count && Set(Self.after).count == Self.after.count)
        for words in Self.before {
            #expect(words.hasSuffix(" Nothing was sent.") && words.components(separatedBy: "Nothing was sent").count == 2,
                    "\(words)")
        }
        for words in Self.after { #expect(!words.contains("Nothing was sent"), "\(words)") }
        for words in Self.before + Self.after {
            #expect(!words.contains("\n") && !words.contains("  ") && !words.hasSuffix(" "), "\(words)")
        }
        // A hidden character's code is said only in its own form.
        #expect(AnswerDoor.words(.hidden("U+202E")).contains("(U+202E)"))
        #expect(!AnswerDoor.words(.hidden("zq-marker")).contains("zq"))
    }

    /// **Only the program's own words of `answer_needs_you` have the door's sentences**, after the table's words: the
    /// program sends such a press to the app, and `owner_mcp.py`, whose table this is, cannot sign one.
    @Test func theProgramsOwnWordsOfTheToolSayHowItPressesTheDoorsCard() throws {
        let table = try #require(Fixture.table.tool(AnswerDoor.name))
        #expect(!table.description.contains("door_call"))
        let listed = OwnerTools.programTable(Fixture.table).tools.filter { $0.name == AnswerDoor.name }
        #expect(listed.map(\.description) == [table.description + " " + AnswerDoor.description])
        #expect(AnswerDoor.description.contains("Press one of the two only when the owner chose it"))
    }

    /// **A server goes into a result only in a server's own form**, the door's own (`DoorCall.isHost`).
    @Test func theServerOfAResultHasTheDoorsOwnForm() {
        for host in ["web-1", "a", "db.example", "1x", "Web-1", "web_1", "-web", ".web", "web 1", "wéb",
                     String(repeating: "a", count: 63), String(repeating: "a", count: 64), ""] {
            #expect(AnswerDoor.isHost(host) == DoorCall.isHost(host), "\(host)")
        }
        let read = AnswerDoor.Read(need: 31, press: .fullAccess, generation: "g1")
        #expect(AnswerDoor.result(read, .init(open: true, doorCall: true, host: "Web 1"))["server"] == nil)
        #expect(AnswerDoor.result(read, DoorPressSample.runCard)["server"] == .string("web-1"))
    }
}

// ------------------------------------------------------------ the program

/// **The program's route**: a door card's Run it once or Full access goes to the app, and the program sends the hub
/// no answer for it; every other answer goes to the hub as before, with no signature, after the same one read.
final class OwnerAnswerDoorProgramTests {
    let home = Fixture.home()
    deinit { try? FileManager.default.removeItem(at: home) }

    static let taken = JSONValue.object(["need": .int(31), "choice": .int(0), "answered": .bool(true),
                                         "signed": .string("door-call"), "note": .string(AnswerDoor.noteRunOnce)])

    private func tools(_ hub: StandInHub, _ link: ValueLink) -> OwnerTools {
        let base = hub.base
        let context = OwnerContext(hubSetting: { base }, transport: Fixture.transport(), home: home,
                                   userAgent: "founderizer-cli/test", ownBuild: nil, startedBuild: { nil },
                                   clientLabel: { "founderizer-cli/1/test" }, appLink: link.appLink())
        return OwnerTools(table: Fixture.table, context: context)
    }

    /// A hub whose state has these items.
    private func hub(_ needs: [JSONValue]) -> StandInHub {
        let hub = StandInHub(features: [])
        hub.state = ["needs": .array(needs)]
        return hub
    }

    /// **A door card's signed press goes to the app, whole, and the hub gets no answer from the program**: Run it once
    /// on every door card, also an answered one (the app says which answer it has), and Full access on a card with a
    /// server. The program read the state once, and the app takes the fields that it sent.
    @Test func aDoorCardsSignedPressGoesToTheApp() throws {
        let cases: [(JSONValue, Int64)] = [
            (DoorPressSample.item(), 0), (DoorPressSample.item(), 1), (DoorPressSample.item(host: nil), 0),
            (DoorPressSample.item(answer: "Run it once", chosen: 0), 0),
        ]
        for (item, choice) in cases {
            let hub = hub([DoorPressSample.item(id: 30, call: nil, host: nil), item])
            let link = ValueLink(.answer(.result(Self.taken)))
            let program = tools(hub, link)
            let (text, isError) = program.call("answer_needs_you", .object(["need": .int(31), "choice": .int(choice)]))
            #expect(!isError && JSONValue.parse(text) == Self.taken, "\(text)")
            #expect(hub.seen.map { "\($0.method) \($0.path)" } == ["GET /ui/state"], "\(choice)")
            let sent = try #require(link.all.first)
            #expect(link.all.count == 1 && sent.0.tool == "answer_needs_you" && sent.0.set == "owner" && sent.1 == nil)
            #expect(sent.0.fields == DoorPressSample.request(choice))
            #expect(AnswerDoor.read(sent.0.fields) == .success(.init(need: 31, press: AnswerDoor.Press(rawValue: choice)!,
                                                                     generation: "g1")))
        }
    }

    /// **Every other answer goes to the hub as before**, with no statement, after the same one read of the state:
    /// words, ticked options, the option No of a door card, Full access on a card with no server, an option of an item
    /// with no door call, a choice that is no JSON integer, a choice beside words, and an item that the state does not
    /// have. Nothing goes to the app.
    @Test func everyOtherAnswerGoesToTheHub() throws {
        let plain = DoorPressSample.item(call: nil, host: nil)
        let cases: [(JSONValue, [String: JSONValue])] = [
            (DoorPressSample.item(), ["answer": .string("Not yet.")]),
            (DoorPressSample.item(), ["choices": .array([.int(0)])]),
            (DoorPressSample.item(), ["choice": .int(2)]),
            (DoorPressSample.item(host: nil), ["choice": .int(1)]),
            (DoorPressSample.item(call: "", host: "web-1"), ["choice": .int(0)]),
            (plain, ["choice": .int(0)]),
            (DoorPressSample.item(), ["choice": .double(0)]),
            (DoorPressSample.item(), ["choice": .int(0), "answer": .string("Run it once")]),
            (DoorPressSample.item(id: 30), ["choice": .int(0)]),
        ]
        for (item, fields) in cases {
            let hub = hub([item])
            let link = ValueLink()
            let program = tools(hub, link)
            let (text, isError) = program.call("answer_needs_you", .object(fields.merging(["need": .int(31)]) { $1 }))
            #expect(!isError, "\(fields): \(text)")
            #expect(hub.seen.map { "\($0.method) \($0.path)" } == ["GET /ui/state", "POST /ui/needs/31"], "\(fields)")
            let body = try #require(hub.seen.last?.body?.object)
            #expect(body["statement"] == nil && body["signature"] == nil && body["db"] == .string("g1"), "\(fields)")
            #expect(link.all.isEmpty, "\(fields)")
        }
    }

    /// **A wrong `need` is the same refusal on both routes, before any request**, and a lost answer of the app has
    /// the press's own words, never "call the tool again" alone.
    @Test func aWrongNeedIsRefusedFirstAndALostAnswerHasThePressesWords() {
        let hub = hub([DoorPressSample.item()])
        let link = ValueLink()
        let program = tools(hub, link)
        for need: JSONValue in [.string("five"), .double(31.5), .bool(true)] {
            #expect(program.call("answer_needs_you", .object(["need": need, "choice": .int(0)]))
                    == ("need must be a whole number.", true))
        }
        #expect(hub.seen.isEmpty && link.all.isEmpty)
        for words in [ChannelClient.noAnswer, ChannelClient.closedNoAnswer, ChannelClient.unreadable] {
            let lost = tools(hub, ValueLink(.failed(words)))
            #expect(lost.call("answer_needs_you", .object(["need": .int(31), "choice": .int(1)]))
                    == (AnswerDoor.notKnownHere, true))
        }
        let refused = tools(hub, ValueLink(.answer(.refused(AnswerDoor.noOwnerKey))))
        #expect(refused.call("answer_needs_you", .object(["need": .int(31), "choice": .int(0)]))
                == (AnswerDoor.noOwnerKey, true))
    }
}
