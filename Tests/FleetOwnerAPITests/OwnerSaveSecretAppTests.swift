import CryptoKit
import Foundation
import Testing
@testable import FleetCore
@testable import FleetOwnerAPI

// **The app's side of `save_secret`** (the secrets plan, step E3): the answer to one call, in its order, and the work
// that outlives its call, with a stand-in desk and no socket. The stand-in uses the app's own types for each rule
// that the wiring gets from FleetCore (`LoginSecret`, `SecretRoom` with `SecretNameHeld`, `VaultSealKey`, `AgeSeal`,
// `SecretCommand`, `SecretFingerprint`), so a rule that the tool and the form read in two ways fails here. No test
// sends anything, reads the real clipboard or sleeps for a fixed time: a test waits with a bound of looks, and only
// a wait's own limit, which the test sets, takes real time.

/// **The app's engine for `save_secret` as stand-ins**: the fleet as the app reads it, the hub's answer to each
/// send, the clipboard, and a record of what the desk was asked, in its order.
@MainActor
final class StandInVaultDesk {
    struct Place: Equatable, Sendable {
        var hub = "https://hub.example.com"
        var database = "gen-1"
    }

    /// A weak look at one box of the tool: nil when nothing holds the box any more.
    final class Look { weak var box: SaveSecret.Kept? }

    static let fleet = "0f1e2d3c4b5a6978"
    /// The central vault's key and another one: the public halves of two keys that are made here and dropped.
    static let vaultKey = AgeSeal.bech32("age", Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
    static let otherKey = AgeSeal.bech32("age", Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)

    /// One reading of `GET /ui/vault`, as the hub writes it.
    static func reading(central: Bool = true, ok: Bool = true, recipient: String? = vaultKey,
                        recovery: String? = otherKey, fleet: String? = StandInVaultDesk.fleet) throws -> VaultReading {
        var status: [String: Any] = ["ok": ok, "fleet": (fleet as Any?) ?? NSNull(), "owner_keys": 1,
                                     "pins": [String: Any](), "grants": [Any](), "pool": [Any](), "items": 2]
        status["recipient"] = (recipient as Any?) ?? NSNull()
        status["recovery"] = (recovery as Any?) ?? NSNull()
        let vault: Any = central ? status : NSNull()
        let body: [String: Any] = ["db": "gen-1", "fleet": (fleet as Any?) ?? NSNull(), "central": vault,
                                   "read_at": 1_761_300_100.5, "error": NSNull(), "machines": [Any](),
                                   "held": [String: Any]()]
        return try JSONDecoder().decode(VaultReading.self, from: JSONSerialization.data(withJSONObject: body))
    }

    /// **The secret of a call's fields as the form's own type holds it**: the helper that the app's wiring uses
    /// (`SecretOfFields` in FleetCore, through `LinkTools.form`), so each test of the tool's logic asks the rule that
    /// the app asks.
    static func form(_ fields: SaveSecret.Fields) -> SecretOfFields {
        SecretOfFields(kind: kind(fields.kind), env: fields.env, url: fields.url, username: fields.username)
    }

    /// The form's own type with the fields of a call, and no value.
    static func secret(of fields: SaveSecret.Fields) -> LoginSecret { form(fields).secret }

    static func kind(_ kind: SaveSecret.Kind) -> LoginSecret.Kind {
        switch kind {
        case .login: return .login
        case .apiKey: return .apiKey
        }
    }

    /// The fields of an item, as the vault reads them.
    static func item(_ bytes: Data) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: bytes) as? [String: String]) ?? [:]
    }

    /// One call of the hub's step, as the stand-in took it.
    struct Register {
        let reference: String
        let title: String
        let kind: LoginSecret.Kind
        let variable: String?
        /// The `address` of the command, or nil when the command has none.
        let address: String?
        /// The command's body, as the form's own code writes it.
        let body: [String: Any]
        /// The fields of the item that came with the call.
        let item: [String: String]
    }

    /// One awaited step of the desk, as it went on after its wait: its closure, and whether the task that it ran in
    /// was cancelled then.
    struct Step: Equatable, Sendable {
        let name: String
        let cancelled: Bool
    }

    // The fleet, as the app reads it.
    var ready = true
    var features = [CentralVault.feature, "secret_grants", SecretCommand.keyTableFeature]
    /// The hub and the database that the app's reading shows now. A save reads and sends with the ones of its own
    /// call (`Place()`): a test moves this, as another hub in the app or a new generation of the hub does.
    var shows = Place()
    /// From this ask of the key on (the first ask is 1), the app shows another database than the one that the
    /// save reads with: its reading moved while the key was read.
    var movedFromAsk: Int?
    var reading: VaultReading?
    /// This Mac's pins, by the fleet's id, as `CentralVaultPins` keeps them for one hub.
    var pins = [StandInVaultDesk.fleet: StandInVaultDesk.vaultKey]
    /// From this ask of the key on (the first ask is 1), this Mac's pin is another key than the vault's: the key
    /// changed while a save was on its way.
    var otherKeyFromAsk: Int?
    private var keyAsks = 0
    var readingFails = false
    var logins: [String: TeamLogin]? = [:]
    var listFails = false
    /// The form's own type takes no secret with a value, or the seal gives no copy.
    var itemFails = false
    var sealFails = false
    /// What the hub answers to each send, in the order of the sends: nil when it took it. The last one serves each
    /// later send too.
    var registerAnswers: [(any Error)?] = [nil]
    var intakeAnswers: [(any Error)?] = [nil]

    // What the desk was asked.
    var asked: [String] = []
    var references: [String] = []
    var seals: [(item: [String: String], key: String)] = []
    var registers: [Register] = []
    var intakes: [(reference: String, sealed: String)] = []
    var refreshes = 0
    /// The places that the sends came with.
    var places: [Place] = []
    /// **Each awaited step, in its order, with whether its task was cancelled when the step went on** (`sealKey`,
    /// `room`, `register`, `intake`, each right after its wait). A step of a call (`room`, and `sealKey` in a
    /// call's check) runs in the call's task, and it sees the cancel of that call by design: the end of the
    /// connection. A step of the work (`register`, `intake`, and `sealKey` in a later run) runs in a task of the
    /// table, and it must never see a cancel: no call's end may stop a save between its two sends.
    var steps: [Step] = []

    // The clipboard: what a read gives, how often it was read, its count now (another writer moves it), and the
    // counts that each clear was given, with whether it cleared.
    var clipboard: SaveBotToken.Clipboard = .text(exampleSecretValue, count: 41)
    var clipboardReads = 0
    var clipboardCount = 41
    var clears: [(Int, Bool)] = []
    /// The closure whose call cancels the task that called it, as the end of the call's connection does.
    var cancelAt: String?

    /// The closures that stop until the test opens them, and the calls that stand there now.
    var holdAt: Set<String> = []
    private var held: [(name: String, go: CheckedContinuation<Void, Never>)] = []

    let table: LinkWork
    var looks: [Look] = []

    init(waitMax: Duration = .seconds(10)) throws {
        table = LinkWork(waitMax: waitMax)
        reading = try Self.reading()
    }

    private func hold(_ name: String) async {
        guard holdAt.contains(name) else { return }
        await withCheckedContinuation { held.append((name, $0)) }
    }

    /// The wait of one awaited step, and then the record of whether its task was cancelled as it went on.
    private func step(_ name: String) async {
        await hold(name)
        steps.append(Step(name: name, cancelled: Task.isCancelled))
    }

    /// **The steps of the work, for a desk that had one save**: `register` and `intake`, which only a run makes,
    /// and each `sealKey` after the first `register`, which is the read of the key in a later run. The steps
    /// before the first `register` (`sealKey`, `room`) are the call's own checks, and they are not in this list.
    var workSteps: [Step] {
        guard let first = steps.firstIndex(where: { $0.name == "register" }) else { return [] }
        return Array(steps[first...])
    }

    /// The hub's features as a save may read them, by the rule that the app's wiring asks (`ShownFeatures` in
    /// FleetCore): nil when the app shows another hub or database than the save's.
    private func featuresShown(for place: Place) -> [String]? {
        guard let hub = URL(string: shows.hub), let sendsTo = URL(string: place.hub) else { return nil }
        return ShownFeatures.of(features, hub: hub, database: shows.database, sendsTo: (sendsTo, place.database))
    }

    /// The calls that stand at one closure now.
    func holds(_ name: String) -> Int { held.filter { $0.name == name }.count }

    /// Lets one call that stands at a closure go on: the first one, or the one at `index` in the order of their
    /// coming.
    func open(_ name: String, _ index: Int = 0) {
        let places = held.indices.filter { held[$0].name == name }
        guard index < places.count else { return }
        held.remove(at: places[index]).go.resume()
    }

    private static func next(_ answers: inout [(any Error)?]) -> (any Error)? {
        guard let first = answers.first else { return nil }
        if answers.count > 1 { answers.removeFirst() }
        return first
    }

    private func cancelIf(_ name: String) {
        if cancelAt == name { withUnsafeCurrentTask { $0?.cancel() } }
    }

    var desk: SaveSecret.Desk<Place> {
        SaveSecret.Desk(
            secret: { [self] fields in
                asked.append("secret")
                // As the app's wiring does it (`LinkTools.secretDesk`): the type's check of the fields alone, with
                // a stand-in for the value, which no rule of a field reads. A title is read only after it.
                let typed = Self.form(fields)
                guard let name = typed.name(standIn: String(repeating: "x", count: SaveSecret.valueLeast)) else {
                    return nil
                }
                let draft = SaveSecret.Draft(title: name.title, kind: fields.kind, variable: name.variable)
                return SaveSecret.Secret(draft: draft) { [self] text in
                    asked.append("item")
                    guard !itemFails else { return nil }
                    return typed.item(value: text)
                }
            },
            ready: { [self] in
                asked.append("ready")
                return ready ? Place() : nil
            },
            sealKey: { [self] place in
                asked.append("sealKey")
                places.append(place)
                await step("sealKey")
                if readingFails { throw SaveBotToken.HubFailure.noAnswer }
                keyAsks += 1
                // As the app's wiring does it: after the read, a reading of the app that shows another hub or
                // database is `moved`, before the rule is asked.
                if let from = movedFromAsk, keyAsks >= from { shows.database = "gen-2" }
                guard let shown = featuresShown(for: place) else { return .moved }
                var pins = pins
                if let from = otherKeyFromAsk, keyAsks >= from { pins[Self.fleet] = Self.otherKey }
                // The pin that the form uses: through the reading's fleet id.
                let pin = reading?.fleetID.flatMap { pins[$0] }
                switch VaultSealKey.of(reading, served: shown.contains(CentralVault.feature), pin: pin) {
                case .key(let key): return .key(key)
                case .noVault: return .noVault
                case .noPin: return .noPin
                case .otherKey: return .otherKey
                case .noRecovery: return .noRecovery
                }
            },
            room: { [self] _, draft in
                asked.append("room")
                await step("room")
                cancelIf("room")
                if listFails { throw SaveBotToken.HubFailure.noAnswer }
                switch SecretRoom.of(title: draft.title, kind: Self.kind(draft.kind), logins: logins, but: nil) {
                case .free: return .free
                case .held: return .held
                case .full: return .full
                case .unread: return .unread
                }
            },
            seal: { [self] item, key in
                asked.append("seal")
                guard !sealFails else { return nil }
                seals.append((Self.item(item), key))
                return try? AgeSeal.seal(item, to: key)
            },
            register: { [self] place, reference, draft, fields, item in
                asked.append("register")
                places.append(place)
                // The hub's step as the form's own code writes it: the fingerprints of the item, and the command
                // with an API key's address by the form's own rule.
                let salts = SecretSalts(login: reference, password: "00112233445566778899aabbccddeeff",
                                        totp: "ffeeddccbbaa99887766554433221100")
                let address = Self.form(fields).address(features: featuresShown(for: place))
                let command = try SecretCommand.add(requestID: UUID(), database: place.database, login: reference,
                                                    title: draft.title, kind: Self.kind(draft.kind),
                                                    variable: draft.variable, address: address,
                                                    fingerprints: SecretFingerprint.of(item, salts: salts))
                let body = (try JSONSerialization.jsonObject(with: command) as? [String: Any]) ?? [:]
                registers.append(Register(reference: reference, title: draft.title, kind: Self.kind(draft.kind),
                                          variable: draft.variable, address: body["address"] as? String, body: body,
                                          item: Self.item(item)))
                await step("register")
                if let failure = Self.next(&registerAnswers) { throw failure }
                logins?[reference] = TeamLogin(title: draft.title, protected: true, kind: draft.kind.rawValue,
                                               env: draft.variable)
            },
            intake: { [self] place, reference, sealed in
                asked.append("intake")
                places.append(place)
                // The vault's step as the form's own code writes it: the command takes the sealed copy.
                _ = try VaultCommand.intake(requestID: UUID(), database: place.database, login: reference,
                                            ciphertext: sealed)
                intakes.append((reference, sealed))
                await step("intake")
                if let failure = Self.next(&intakeAnswers) { throw failure }
            },
            refresh: { [self] in
                asked.append("refresh")
                refreshes += 1
            },
            newReference: { [self] in
                asked.append("reference")
                let reference = "bws://" + UUID().uuidString.lowercased()
                references.append(reference)
                return reference
            },
            readClipboard: { [self] in
                asked.append("clipboard")
                clipboardReads += 1
                await hold("clipboard")
                // As the connection's end does while macOS's question waits for the owner.
                cancelIf("clipboard")
                return clipboard
            },
            clearClipboard: { [self] count in
                asked.append("clear")
                let cleared = count == clipboardCount
                clears.append((count, cleared))
                return cleared
            })
    }

    /// One call of the tool, with a value part of this text or of these bytes, or with none.
    func answer(_ fields: [String: JSONValue], _ value: String? = nil, bytes: [UInt8]? = nil) async -> OwnerChannel.Answer {
        let part = (bytes ?? value.map { Array($0.utf8) }).map { OwnerChannel.Value(copying: $0) }
        return await SaveSecret.answer(fields: fields, value: part, desk: desk, work: table) { [self] box in
            let look = Look()
            look.box = box
            looks.append(look)
        }
    }

    /// The state of an id when its work runs no more, with no call of `wait`: no call is counted.
    func end(of id: String) async -> LinkWork.State? {
        await SaveSecretCalls.until {
            if case .running? = self.table.state(of: id) { return false }
            return true
        }
        return table.state(of: id)
    }

    /// Nothing holds a box any more: each look is nil.
    func boxesGone() async -> Bool {
        await SaveSecretCalls.until { self.looks.allSatisfy { $0.box == nil } }
        return looks.allSatisfy { $0.box == nil }
    }
}

/// What the tests of the app's side share: made-up calls, the answers that they expect, and the two waits.
@MainActor
enum SaveSecretCalls {
    /// A limit of a wait that a test waits to its end.
    static let near = Duration.milliseconds(50)

    /// A made-up id of the one form.
    static func id(_ number: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", number) }

    /// A save of an API key, as the program sends it.
    static func key(_ number: Int = 1, from: String = "file", env: String = "EXAMPLE_API_KEY",
                    url: String? = nil) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["request_id": .string(id(number)), "kind": .string("api_key"),
                                           "env": .string(env), "from": .string(from)]
        if let url { fields["url"] = .string(url) }
        return fields
    }

    /// A save of a login, as the program sends it.
    static func login(_ number: Int = 1, from: String = "file", url: String = "https://shop.example.com/login",
                      username: String = "owner@example.com") -> [String: JSONValue] {
        ["request_id": .string(id(number)), "kind": .string("login"), "url": .string(url),
         "username": .string(username), "from": .string(from)]
    }

    /// A read of a save's state.
    static func state(_ number: Int = 1) -> [String: JSONValue] { ["request_id": .string(id(number))] }

    /// The answer of a save that is done.
    static func done(_ number: Int = 1, _ reference: String, title: String = "EXAMPLE_API_KEY", kind: String = "api_key",
                     clipboard: String? = nil) -> OwnerChannel.Answer {
        var answer: [String: JSONValue] = ["request_id": .string(id(number)), "state": .string("done"),
                                           "reference": .string(reference), "title": .string(title),
                                           "kind": .string(kind)]
        if let clipboard { answer["clipboard"] = .string(clipboard) }
        return .result(.object(answer))
    }

    /// The answer of a save that runs.
    static func running(_ number: Int = 1, _ stage: LinkWork.Stage) -> OwnerChannel.Answer {
        .result(.object(["request_id": .string(id(number)), "state": .string("running"),
                         "stage": .string(stage.rawValue)]))
    }

    /// Yields until `done`, with a bound of looks and no sleep: a regression fails at the expectation that follows.
    static func until(_ done: () -> Bool) async {
        for _ in 0..<10_000 where !done() { await Task.yield() }
    }

    /// Room for a task that must not exist: it would run in these looks, and the expectation that follows sees it.
    static func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    /// What a call got, for a test that must see whether the call was answered while it still looks.
    @MainActor
    final class Call {
        private(set) var answer: OwnerChannel.Answer?
        private var task: Task<Void, Never>?

        init(_ app: StandInVaultDesk, _ fields: [String: JSONValue], _ value: String? = nil) {
            task = Task { self.answer = await app.answer(fields, value) }
        }

        var came: Bool { answer != nil }

        /// The call's connection ended.
        func cancel() { task?.cancel() }

        /// The answer, when the call has ended.
        func ended() async -> OwnerChannel.Answer? {
            await task?.value
            return answer
        }
    }

    /// The words of a refusal, or nil for a result.
    static func words(_ answer: OwnerChannel.Answer?) -> String? {
        if case .refused(let words)? = answer { return words }
        return nil
    }

    /// One call in a task of its own, as the listener makes it: a cancel that the stand-in makes ends that task,
    /// and not the test's.
    static func call(_ app: StandInVaultDesk, _ fields: [String: JSONValue], _ value: String? = nil) async -> OwnerChannel.Answer {
        await Task { await app.answer(fields, value) }.value
    }

    /// One save that goes its whole way, with the reference that the app made for it.
    static func saved(_ app: StandInVaultDesk, _ fields: [String: JSONValue],
                      _ value: String? = nil) async -> (answer: OwnerChannel.Answer, reference: String) {
        let answer = await app.answer(fields, value)
        return (answer, app.references.last ?? "")
    }
}

/// **The refusals of `save_secret` in the app**, each before anything was sent: the order of the checks, the list,
/// the vault's key, and what no refusal may hold.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct OwnerSaveSecretRefusalTests {
    typealias Calls = SaveSecretCalls
    typealias Desk = StandInVaultDesk
    let value = exampleSecretValue

    /// **A wrong form is refused before any read**: of the value part, of the table, of the desk and of the
    /// clipboard. Every count of the stand-in desk stays at 0, and the table has no record of the id.
    @Test func aWrongFormIsRefusedBeforeAnyRead() async throws {
        let app = try Desk()
        let key = Calls.key(), login = Calls.login()
        func with(_ base: [String: JSONValue], _ more: [String: JSONValue]) -> [String: JSONValue] {
            base.merging(more) { $1 }
        }
        let cases: [([String: JSONValue], String)] = [
            (with(key, ["env": .string("example_api_key")]), SaveSecret.envWord),
            (with(key, ["env": .string("EXAMPLE_API_KEY\n")]), SaveSecret.envWord),
            (with(key, ["env": .string("XAI_API_KEY")]), SaveSecret.envWord),
            (with(key, ["url": .string("https://claude.ai/login")]), SaveSecret.urlWord),
            (with(key, ["url": .string("https://example.com/a b")]), SaveSecret.urlWord),
            (with(login, ["url": .string("example.com")]), SaveSecret.urlWord),
            (with(login, ["username": .string("own er")]), SaveSecret.userWord),
            (with(login, ["username": .string("")]), SaveSecret.userWord),
            (with(key, ["kind": .string("card")]), SaveSecret.kindWord),
            (with(key, ["username": .string("owner")]), SaveSecret.kindFields),
            (with(login, ["env": .string("EXAMPLE_API_KEY")]), SaveSecret.kindFields),
            (with(key, ["from": .string("paste")]), SaveSecret.fromWord),
            (key.filter { $0.key != "from" }, SaveSecret.needsFrom),
            (with(key, ["path": .string("/tmp/example")]), SaveSecret.appTakesNoPath),
            (key.filter { $0.key != "request_id" }, SaveSecret.appNeedsRequest),
            (with(key, ["request_id": .string(Calls.id(1) + "a")]), SaveSecret.requestWord),
            (with(key, ["request_id": .string(Calls.id(1) + "\n")]), SaveSecret.requestWord),
            (with(key, ["request_id": .string("AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEFFFF")]), SaveSecret.requestWord),
            (with(key, ["token": .string("x")]), OwnerLinkTools.neverAField),
            (with(login, ["seed_from": .string("file")]), SaveSecret.noSeedYet),
            (with(key, ["replace": .bool(true)]), SaveSecret.only),
            ([:], SaveSecret.appNeedsRequest),
        ]
        for (fields, words) in cases {
            for source in ["file", "stdin", "clipboard"] {
                var sent = fields
                if sent["from"] == .string("file") { sent["from"] = .string(source) }
                // With a value part and with none: the fields come first.
                #expect(await app.answer(sent, value) == .refused(words), "\(sent)")
                #expect(await app.answer(sent) == .refused(words), "\(sent)")
            }
        }
        // The value part and its form come before the desk too: no part, a part with the clipboard, and a part
        // that is no value.
        #expect(await app.answer(key) == .refused(SaveSecret.noValue))
        #expect(await app.answer(Calls.key(from: "clipboard"), value) == .refused(SaveSecret.clipboardTakesNoPart))
        for bad in ["short", "example value-0123", "\u{FEFF}" + value, String(repeating: "a", count: 4097), " \n"] {
            #expect(await app.answer(key, bad) == .refused(SaveSecret.notAValue), "\(bad.prefix(12).debugDescription)")
        }
        #expect(await app.answer(key, bytes: [0xFF, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48])
                == .refused(SaveSecret.notAValue))
        #expect(app.asked.isEmpty)
        #expect(app.clipboardReads == 0 && app.references.isEmpty && app.registers.isEmpty && app.intakes.isEmpty)
        #expect(app.refreshes == 0 && app.clears.isEmpty && app.looks.isEmpty && app.places.isEmpty)
        #expect(app.table.state(of: Calls.id(1)) == nil && app.table.waiting == 0)
        // The table was not asked to begin anything: a save under the same id would start as a first one.
        let digest = SaveSecret.digest(of: .init(kind: .apiKey, env: "EXAMPLE_API_KEY"), from: "file")
        #expect(app.table.check(id: Calls.id(1), digest: digest) == .started)
    }

    /// **The app's checks run in their order**: of two faults in one call, the earlier check's sentence is the
    /// answer, and the desk was asked only up to that check. One fault less at each step, to a save that goes.
    @Test func theAppsChecksRunInTheirOrder() async throws {
        // From a file: the value part, its form, the form's own type, the reading, the key, the room, the caller.
        let app = try Desk()
        let key = Calls.key()
        app.itemFails = true
        app.ready = false
        app.features = []
        app.logins = nil
        app.cancelAt = "room"
        #expect(await app.answer(key) == .refused(SaveSecret.noValue))
        #expect(await app.answer(key, "short") == .refused(SaveSecret.notAValue))
        #expect(app.asked.isEmpty)
        #expect(await app.answer(key, value) == .refused(SaveSecret.formRefused))
        #expect(app.asked == ["secret", "item"])
        app.itemFails = false
        app.asked = []
        #expect(await app.answer(key, value) == .refused(SaveSecret.notReady))
        #expect(app.asked == ["secret", "item", "reference", "ready"])
        app.ready = true
        app.asked = []
        #expect(await app.answer(key, value) == .refused(SaveSecret.noVault))
        #expect(app.asked == ["secret", "item", "reference", "ready", "sealKey"])
        app.features = [CentralVault.feature]
        app.asked = []
        #expect(await Calls.call(app, key, value) == .refused(SaveSecret.listUnread))
        #expect(app.asked == ["secret", "item", "reference", "ready", "sealKey", "room"])
        // The caller went away during the read of the list: the list has room, and nothing begins.
        app.logins = [:]
        app.asked = []
        #expect(await Calls.call(app, key, value) == .refused(SaveSecret.endedBeforeBegin))
        #expect(app.asked == ["secret", "item", "reference", "ready", "sealKey", "room"])
        #expect(app.table.state(of: Calls.id(1)) == nil && app.registers.isEmpty)
        app.cancelAt = nil
        app.asked = []
        let went = await Calls.saved(app, key, value)
        #expect(went.answer == Calls.done(1, went.reference))
        #expect(app.asked == ["secret", "item", "reference", "ready", "sealKey", "room", "seal", "register", "intake",
                              "refresh"])
        #expect(await app.boxesGone())

        // From the clipboard: no value part, the form's own type on the fields, the reading, the key, the room,
        // and the clipboard last.
        let other = try Desk()
        let unread = Calls.key(2, from: "clipboard", url: "https://xn--a.example.com/pathmark")
        other.ready = false
        other.pins = [:]
        other.logins = ["bws://" + Calls.id(9): TeamLogin(title: "EXAMPLE_API_KEY", protected: true, kind: "api_key",
                                                           env: "EXAMPLE_API_KEY")]
        other.clipboard = .notAllowed
        #expect(await other.answer(unread, value) == .refused(SaveSecret.clipboardTakesNoPart))
        #expect(other.asked.isEmpty)
        #expect(await other.answer(unread) == .refused(SaveSecret.formRefused))
        #expect(other.asked == ["secret"])
        let good = Calls.key(2, from: "clipboard")
        other.asked = []
        #expect(await other.answer(good) == .refused(SaveSecret.notReady))
        #expect(other.asked == ["secret", "ready"])
        other.ready = true
        other.asked = []
        #expect(await other.answer(good) == .refused(SaveSecret.noPin))
        #expect(other.asked == ["secret", "ready", "sealKey"])
        other.pins = [Desk.fleet: Desk.vaultKey]
        other.asked = []
        #expect(await other.answer(good) == .refused(SaveSecret.held))
        #expect(other.asked == ["secret", "ready", "sealKey", "room"])
        other.logins = [:]
        other.asked = []
        #expect(await other.answer(good) == .refused(SaveSecret.clipboardDenied))
        #expect(other.asked == ["secret", "ready", "sealKey", "room", "clipboard"])
        other.clipboard = .text("short", count: 7)
        #expect(await other.answer(good) == .refused(SaveSecret.notOnClipboard))
        other.clipboard = .text(value, count: 7)
        other.itemFails = true
        other.asked = []
        #expect(await other.answer(good) == .refused(SaveSecret.formRefused))
        #expect(other.asked == ["secret", "ready", "sealKey", "room", "clipboard", "item"])
        #expect(other.registers.isEmpty && other.table.state(of: Calls.id(2)) == nil)
        other.itemFails = false
        other.clipboardCount = 7
        other.asked = []
        let copied = await Calls.saved(other, good)
        #expect(copied.answer == Calls.done(2, copied.reference, clipboard: "cleared"))
        #expect(other.asked == ["secret", "ready", "sealKey", "room", "clipboard", "item", "reference", "seal",
                                "register", "intake", "refresh", "clear"])
    }

    /// **A secret that the form's own type refuses is refused before the desk is asked for anything else**, and
    /// its title is never read. The address has a label that is no valid name in its coding: it passes the tool's
    /// form, the type reads no host in it, and the type's title of it would be the WHOLE address, with its path.
    /// From a file, a pipe and the clipboard, for a login and for a key: `formRefused`, and nothing after it.
    @Test func aSecretThatTheFormsTypeRefusesIsRefusedBeforeTheDeskIsAskedForMore() async throws {
        let site = "https://xn--a.example.com/pathmark"
        #expect(SaveSecret.isSite(site))
        var typed = Desk.secret(of: .init(kind: .login, url: site, username: "owner"))
        typed.password = value
        #expect(typed.problem != nil)
        // What the rule keeps out of the list: the type's title of this secret holds the path.
        #expect(typed.title.contains("pathmark"))
        let app = try Desk()
        for (number, source) in ["file", "stdin", "clipboard"].enumerated() {
            for fields in [Calls.login(number + 1, from: source, url: site, username: "owner"),
                           Calls.key(number + 1, from: source, url: site)] {
                app.asked = []
                #expect(await app.answer(fields, source == "clipboard" ? nil : value) == .refused(SaveSecret.formRefused))
                #expect(app.asked == ["secret"], "\(source)")
                #expect(app.table.state(of: Calls.id(number + 1)) == nil)
            }
        }
        #expect(app.clipboardReads == 0 && app.references.isEmpty && app.looks.isEmpty && app.registers.isEmpty)
        // The same call with an address that the type reads goes, and its title has the host and no path.
        let good = Calls.login(7, url: "https://xn--bcher-kva.example.com/pathmark", username: "owner")
        let went = await Calls.saved(app, good, value)
        #expect(went.answer == Calls.done(7, went.reference, title: "b\u{FC}cher.example.com · owner", kind: "login"))
        #expect(app.registers.count == 1 && app.registers.first?.title.contains("pathmark") == false)
    }

    /// **A name that the list has is refused**, by the form's own rule (`SecretRoom.of`): a key of this variable
    /// name, also under another title, and a login of this title. Nothing is sent, and the clipboard is not read.
    /// A name that the list does not have goes, and the same name again is then held: the tool saves only a new
    /// secret.
    @Test func aNameThatTheListHasIsRefused() async throws {
        let app = try Desk()
        app.logins = ["bws://" + Calls.id(91): TeamLogin(title: "An older name", protected: true, kind: "api_key",
                                                          env: "EXAMPLE_API_KEY"),
                      "bws://" + Calls.id(92): TeamLogin(title: "shop.example.com · owner@example.com", protected: true,
                                                          kind: "login")]
        #expect(await app.answer(Calls.key(1), value) == .refused(SaveSecret.held))
        #expect(await app.answer(Calls.key(2, from: "clipboard")) == .refused(SaveSecret.held))
        #expect(await app.answer(Calls.login(3), value) == .refused(SaveSecret.held))
        #expect(await app.answer(Calls.login(4, from: "clipboard")) == .refused(SaveSecret.held))
        #expect(app.registers.isEmpty && app.intakes.isEmpty && app.clipboardReads == 0 && app.seals.isEmpty)
        for number in 1...4 { #expect(app.table.state(of: Calls.id(number)) == nil) }
        // A value that was made into an item before the refusal went with its box.
        #expect(app.looks.count == 2)
        #expect(await app.boxesGone())
        // Another name goes. The same name under a new id is then held, because the list has it now.
        let went = await Calls.saved(app, Calls.key(5, env: "OTHER_API_KEY"), value)
        #expect(went.answer == Calls.done(5, went.reference, title: "OTHER_API_KEY"))
        #expect(app.registers.count == 1)
        #expect(await app.answer(Calls.key(6, env: "OTHER_API_KEY"), value) == .refused(SaveSecret.held))
        #expect(app.registers.count == 1 && app.intakes.count == 1)
        #expect(SaveSecret.held.hasSuffix("Nothing was sent."))
    }

    /// **A full list is refused**, and a list that the hub did not give: 256 entries take no more, 255 take one,
    /// and a read of the list that failed, or a hub with no list, says that the list could not be read.
    @Test func aFullListIsRefused() async throws {
        func many(_ count: Int) -> [String: TeamLogin] {
            var list: [String: TeamLogin] = [:]
            for index in 0..<count {
                let name = "FILLER_\(index)_KEY"
                list[String(format: "bws://00000000-0000-4000-8000-%012x", index)] =
                    TeamLogin(title: name, protected: true, kind: "api_key", env: name)
            }
            return list
        }
        let app = try Desk()
        app.logins = many(LoginSecret.maxCatalog)
        #expect(await app.answer(Calls.key(1), value) == .refused(SaveSecret.full))
        #expect(await app.answer(Calls.login(2, from: "clipboard")) == .refused(SaveSecret.full))
        // The name comes before the room, as in the form.
        #expect(await app.answer(Calls.key(3, env: "FILLER_7_KEY"), value) == .refused(SaveSecret.held))
        app.logins = nil
        #expect(await app.answer(Calls.key(4), value) == .refused(SaveSecret.listUnread))
        app.logins = [:]
        app.listFails = true
        #expect(await app.answer(Calls.key(5, from: "clipboard")) == .refused(SaveSecret.listUnread))
        #expect(app.registers.isEmpty && app.clipboardReads == 0)
        app.listFails = false
        app.logins = many(LoginSecret.maxCatalog - 1)
        let went = await Calls.saved(app, Calls.key(6), value)
        #expect(went.answer == Calls.done(6, went.reference))
        #expect(app.logins?.count == LoginSecret.maxCatalog && SaveSecret.listMost == LoginSecret.maxCatalog)
    }

    /// **No vault, no pin, another key and no recovery key send nothing**: the five answers of the form's own rule
    /// (`VaultSealKey.of`, with the pin that the form uses, through the reading's fleet id), each with its own
    /// sentence, and the one key that a value is sealed to. A read of the vault's status that failed has a
    /// sentence of its own: that the vault does not answer the hub is not known when the hub did not answer the Mac.
    @Test func noVaultAnotherKeyAndNoRecoverySendNothing() async throws {
        let cases: [(String, (Desk) throws -> Void, String)] = [
            ("the hub does not serve the vault", { $0.features = ["secret_grants"] }, SaveSecret.noVault),
            ("no reading", { $0.reading = nil }, SaveSecret.noVault),
            ("no vault in the reading", { $0.reading = try Desk.reading(central: false) }, SaveSecret.noVault),
            ("a status that is not good", { $0.reading = try Desk.reading(ok: false) }, SaveSecret.noVault),
            ("a reading that names no fleet", { $0.reading = try Desk.reading(fleet: nil) }, SaveSecret.noVault),
            ("a read that failed", { $0.readingFails = true }, SaveSecret.vaultUnread),
            ("no pin", { $0.pins = [:] }, SaveSecret.noPin),
            ("a pin of another fleet only", { $0.pins = ["ffffffffffffffff": Desk.vaultKey] }, SaveSecret.noPin),
            ("another key than the pinned one", { $0.pins = [Desk.fleet: Desk.otherKey] }, SaveSecret.otherKey),
            ("a vault with another key", { $0.reading = try Desk.reading(recipient: Desk.otherKey) }, SaveSecret.otherKey),
            ("no key that can be read", { $0.reading = try Desk.reading(recipient: nil) }, SaveSecret.otherKey),
            ("no recovery key", { $0.reading = try Desk.reading(recovery: nil) }, SaveSecret.noRecovery),
        ]
        for (name, change, words) in cases {
            let app = try Desk()
            try change(app)
            #expect(await app.answer(Calls.key(1), value) == .refused(words), "\(name)")
            #expect(await app.answer(Calls.login(2, from: "clipboard")) == .refused(words), "\(name)")
            #expect(app.asked.last == "sealKey" && !app.asked.contains("room"), "\(name)")
            #expect(app.seals.isEmpty && app.registers.isEmpty && app.intakes.isEmpty && app.clipboardReads == 0, "\(name)")
            #expect(app.table.state(of: Calls.id(1)) == nil && app.table.state(of: Calls.id(2)) == nil, "\(name)")
            #expect(await app.boxesGone(), "\(name)")
        }
        // The one good case: the value is sealed to the vault's key, which is the pinned one, and to no other.
        let app = try Desk()
        let went = await Calls.saved(app, Calls.key(1), value)
        #expect(went.answer == Calls.done(1, went.reference))
        #expect(app.seals.count == 1 && app.seals.first?.key == Desk.vaultKey)
        #expect(Desk.vaultKey != Desk.otherKey && AgeSeal.publicKey(of: Desk.vaultKey) != nil)
        // Each of the five sentences is its own, and the pin's two are apart.
        #expect(Set([SaveSecret.noVault, SaveSecret.vaultUnread, SaveSecret.noPin, SaveSecret.otherKey,
                     SaveSecret.noRecovery]).count == 5)
        #expect(SaveSecret.vaultUnread.hasSuffix("Nothing was sent.") && !SaveSecret.vaultUnread.contains("does not answer"))
    }

    /// **Only the one line end of a file or of stdin is taken off a value, and nothing off the clipboard's text.**
    /// From a file and from stdin, `abcdefgh` with a LF and with a CR LF is saved as `abcdefgh`. With two line ends,
    /// with a space or a tab before the line end, with a space at the start, with a lone CR, with a zero-width space
    /// at an end and with a byte order mark at the start, the text is no value: the call is refused with the one
    /// sentence, and nothing is asked of the desk. From the clipboard, `abcdefgh` is saved, and the same text with a
    /// line end or a space at an end is refused with the clipboard's one sentence: no item is made, nothing is sent
    /// and nothing is cleared. No value is ever saved in another form than the one that came.
    @Test func onlyTheOneLineEndOfAFileOrOfStdinIsTakenOffAValue() async throws {
        let short = "abcdefgh"
        let refused = [short + "\n\n", short + "\r\n\r\n", short + " \n", short + "\t\n", short + " \r\n", short + " ",
                       " " + short + "\n", " " + short, short + "\r", short + "\n\r", short + "\u{200B}",
                       short + "\u{200B}\n", "\u{200B}" + short + "\n", "\u{FEFF}" + short + "\n", "\u{FEFF}" + short,
                       "\n" + short + "\n"]
        var number = 0
        for source in ["file", "stdin"] {
            let app = try Desk()
            for text in refused {
                #expect(await app.answer(Calls.key(1, from: source), text) == .refused(SaveSecret.notAValue),
                        "\(source): \(text.debugDescription)")
            }
            // Nothing was asked of the desk after a refusal, and the table has no record.
            #expect(app.asked.isEmpty && app.looks.isEmpty && app.registers.isEmpty && app.clipboardReads == 0)
            #expect(app.table.state(of: Calls.id(1)) == nil)
            for text in [short, short + "\n", short + "\r\n"] {
                number += 1
                let env = "LINE_\(number)_API_KEY"
                let went = await Calls.saved(app, Calls.key(number, from: source, env: env), text)
                #expect(went.answer == Calls.done(number, went.reference, title: env), "\(source): \(text.debugDescription)")
                #expect(app.registers.last?.item == ["username": "", "password": short], "\(text.debugDescription)")
                #expect(app.seals.last?.item["password"] == short)
            }
            #expect(app.registers.count == 3 && app.intakes.count == 3)
        }

        // The clipboard's text is taken as it is.
        let app = try Desk()
        app.clipboard = .text(short, count: 41)
        let went = await Calls.saved(app, Calls.key(1, from: "clipboard"))
        #expect(went.answer == Calls.done(1, went.reference, clipboard: "cleared"))
        #expect(app.registers.count == 1 && app.registers.first?.item["password"] == short)
        let reads = app.clipboardReads
        let others = [short + "\n", short + "\r\n", short + " ", " " + short, short + "\t", short + "\r",
                      short + "\u{200B}", "\u{FEFF}" + short, "\n" + short] + refused
        app.asked = []
        for text in others {
            app.clipboard = .text(text, count: 42)
            app.clipboardCount = 42
            #expect(await app.answer(Calls.key(2, from: "clipboard", env: "OTHER_API_KEY")) == .refused(SaveSecret.notOnClipboard),
                    "\(text.debugDescription)")
        }
        #expect(app.clipboardReads == reads + others.count && !app.asked.contains("item") && !app.asked.contains("seal"))
        #expect(app.registers.count == 1 && app.clears.count == 1 && app.looks.count == 1)
        #expect(app.table.state(of: Calls.id(2)) == nil)
        // The same texts through a file: the ones that are one line with its line end are values there.
        #expect(SaveSecret.value(of: short + "\n", line: true) == short && SaveSecret.value(of: short + "\n", line: false) == nil)
    }

    /// **The refusals quote nothing**: the marker in each field that has a form for it, in a field's name, as the
    /// value, in the clipboard and in the hub's words to each send, at each run. No refusal holds it, and none
    /// holds the value. The one answer that holds a field's text is the result of a save that is done, in `title`.
    @Test func theRefusalsQuoteNothing() async throws {
        let secretValue = marker + "-" + "value-0123"
        let site = "https://" + marker + ".example.com/" + marker + "?next=" + marker
        let env = marker.uppercased().replacingOccurrences(of: "-", with: "_") + "_KEY"
        #expect(SaveSecret.isSite(site) && SaveSecret.isKeyName(env) && SaveSecret.isUserName(marker))
        #expect(SaveSecret.isValueText(secretValue))
        var refusals: [String] = []
        var results = 0
        func note(_ answer: OwnerChannel.Answer?) {
            switch answer {
            case .refused(let words)?: refusals.append(words)
            case .result(let json)?:
                results += 1
                #expect(!json.dumps().contains(secretValue))
            case nil: Issue.record("no answer")
            }
        }
        let said = "the words of the hub: " + env + " " + marker + " " + secretValue
        func hub(_ status: Int) -> SaveBotToken.HubFailure { .refused(status, said) }

        // Each refusal before the send and each failure of a send, with the marker in every field and as the value.
        let changes: [(Desk) throws -> Void] = [
            { _ in }, { $0.ready = false }, { $0.features = [] }, { $0.pins = [:] },
            { $0.pins = [Desk.fleet: Desk.otherKey] }, { $0.reading = try Desk.reading(recovery: nil) },
            { $0.readingFails = true }, { $0.logins = nil }, { $0.listFails = true }, { $0.itemFails = true },
            { $0.logins = ["bws://" + Calls.id(90): TeamLogin(title: env, protected: true, kind: "api_key", env: env)] },
            { $0.clipboard = .nothing }, { $0.clipboard = .notAllowed }, { $0.clipboard = .busy },
            { $0.clipboard = .text(marker + " " + marker, count: 3) }, { $0.cancelAt = "clipboard" },
            { $0.cancelAt = "room" }, { $0.sealFails = true },
            // The hub's words to the entry and to the value.
            { $0.registerAnswers = [hub(409)] }, { $0.registerAnswers = [hub(503)] }, { $0.registerAnswers = [hub(500)] },
            { $0.registerAnswers = [SaveBotToken.HubFailure.noAnswer, hub(503), hub(409)] },
            { $0.intakeAnswers = [hub(409)] }, { $0.intakeAnswers = [hub(502)] },
            { $0.intakeAnswers = [SaveBotToken.HubFailure.unreadable, hub(503), hub(500)] },
            // Another key at the second run's read of the key.
            { $0.registerAnswers = [SaveBotToken.HubFailure.noAnswer]; $0.otherKeyFromAsk = 2 },
        ]
        for change in changes {
            for source in ["file", "clipboard"] {
                let app = try Desk()
                app.clipboard = .text(secretValue, count: 41)
                try change(app)
                let part = source == "file" ? secretValue : nil
                for fields in [Calls.key(1, from: source, env: env, url: site),
                               Calls.login(2, from: source, url: site, username: marker)] {
                    // The call, and the same call again two times: a later run and the last one, with the hub's
                    // words at each. Then a read of the state, and other fields under the same id.
                    for _ in 0..<3 { note(await Calls.call(app, fields, part)) }
                    note(await Calls.call(app, fields.filter { $0.key == "request_id" }))
                    let other = fields.merging(["from": .string(source == "file" ? "stdin" : "file")]) { $1 }
                    note(await Calls.call(app, other, secretValue))
                }
                #expect(await app.boxesGone())
            }
        }
        // A field's name with the marker, the marker where a field has no form for it, and a value that is none.
        let app = try Desk()
        for fields in [Calls.key().merging([marker: .string(marker)]) { $1 },
                       Calls.key().merging(["kind": .string(marker)]) { $1 },
                       Calls.key(env: marker), Calls.key(url: marker), Calls.login(username: marker + " " + marker),
                       Calls.key().merging(["from": .string(marker)]) { $1 },
                       Calls.key().merging(["request_id": .string(marker)]) { $1 },
                       Calls.key().merging(["path": .string(marker)]) { $1 },
                       Calls.key().merging([marker + "_secret": .string(marker)]) { $1 },
                       Calls.login().merging(["seed_path": .string(marker)]) { $1 }] {
            note(await app.answer(fields, secretValue))
        }
        note(await app.answer(Calls.key(), marker + " " + secretValue))
        note(await app.answer(Calls.key(from: "clipboard"), secretValue))
        #expect(app.asked.isEmpty)
        // While a save runs: busy for another id, and other fields under its own.
        app.holdAt = ["register"]
        let first = Calls.Call(app, Calls.key(3, env: env, url: site), secretValue)
        await Calls.until { app.holds("register") == 1 }
        note(await app.answer(Calls.login(4, url: site, username: marker), secretValue))
        note(await app.answer(Calls.key(3, from: "stdin", env: env, url: site), secretValue))
        app.holdAt = []
        app.open("register")
        note(await first.ended())

        #expect(refusals.count > 200 && results > 20)
        for words in refusals {
            #expect(!words.lowercased().contains(marker) && !words.lowercased().contains("zq"), "\(words)")
            #expect(!words.contains(secretValue) && !words.contains("value-0123"), "\(words)")
            #expect(!words.contains("the words of the hub"), "\(words)")
        }
        // Every kind of refusal after the send came, so the hub's words had their chance.
        for kind in ["Whether the hub took the entry", "is not in the vault yet", "with no value in the vault",
                     "The list may have the entry", "The hub refused the new entry (status 409)",
                     "does not answer the hub now", "Another save_secret runs now", "save with other fields",
                     "has no save of this request_id", "could not read the central vault's status",
                     "could not seal the value", "ended before the save began", "ended while it waited for the clipboard",
                     "this save has ended", "the same from and request_id " + Calls.id(1)] {
            #expect(refusals.contains { $0.contains(kind) }, "\(kind)")
        }
    }

    /// **No answer depends on a search in the value.** A value that is a field's text, holds one, or is held by
    /// one is a value like any other: the save goes. And the caller's repeat joins its save whatever value part
    /// comes with it: the table's digest is of the fields alone, so no answer says whether two values are equal.
    @Test func noAnswerDependsOnASearchInTheValue() async throws {
        let app = try Desk()
        let user = "owner-" + "example-0123"
        let values = ["EXAMPLE_API_KEY", "EXAMPLE_API_KEY-and-more", "API_KEY_", user, "shop.example.com",
                      "https://shop.example.com/login", Calls.id(1), "save_secret", "bws://" + Calls.id(1), value]
        var number = 0
        for text in values {
            #expect(SaveSecret.isValueText(text), "\(text)")
            number += 1
            let key = await Calls.saved(app, Calls.key(number, env: "EXAMPLE_\(number)_API_KEY"), text)
            #expect(key.answer == Calls.done(number, key.reference, title: "EXAMPLE_\(number)_API_KEY"), "\(text)")
            #expect(app.registers.last?.item["password"] == text)
            number += 1
            let login = await Calls.saved(app, Calls.login(number, username: "\(number)-" + user), text)
            #expect(login.answer == Calls.done(number, login.reference, title: "shop.example.com · \(number)-" + user,
                                               kind: "login"), "\(text)")
            #expect(app.registers.last?.item["password"] == text)
        }
        // A user name that is the value itself: saved as it is, with the value compared with nothing.
        let same = await Calls.saved(app, Calls.login(90, username: user), user)
        #expect(same.answer == Calls.done(90, same.reference, title: "shop.example.com · " + user, kind: "login"))
        // The repeat of a call, with the same value part, another one, one that is no value, or none: one answer.
        let again = Calls.key(91, env: "REPEATED_API_KEY")
        let first = await Calls.saved(app, again, value)
        #expect(first.answer == Calls.done(91, first.reference, title: "REPEATED_API_KEY"))
        let sends = app.registers.count
        for part in [value, "other-" + "value-4567", "short", nil] {
            #expect(await app.answer(again, part) == first.answer)
        }
        #expect(await app.answer(again, bytes: [0xFF, 0xFE]) == first.answer)
        #expect(app.registers.count == sends && app.registers.count == 2 * values.count + 2)
        // The digest has no value among its inputs: this line does not build with one.
        let digest: (SaveSecret.Fields, String) -> [UInt8] = SaveSecret.digest(of:from:)
        #expect(digest(.init(kind: .apiKey, env: "REPEATED_API_KEY"), "file").count == 32)
    }
}

