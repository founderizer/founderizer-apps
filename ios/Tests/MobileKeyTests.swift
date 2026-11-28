import CryptoKit
import FleetCore
import Foundation
import Testing
import UserNotifications
@testable import FleetMobile

/// The phone's two locks. The tailnet is the outer one, this phone's key the inner one, and every call of an enrolled
/// device carries that key. These checks hold what no fixture can prove: what goes on the wire, and what each refusal
/// of this device means.
@Suite("This phone's key")
struct MobileKeyTests {
    private let hub = try! MobileClient.address("http://100.96.10.20:8765")

    @Test("An enrolled phone sends its key as a bearer token")
    func keyGoesInTheHeader() {
        let request = MobileClient.request("ui/mobile", hub: hub, key: "a-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer a-key")
    }

    @Test("A phone without a key sends no token, as the owner's own Mac must not")
    func noKeyNoHeader() {
        for key in [nil, ""] as [String?] {
            let request = MobileClient.request("ui/mobile", hub: hub, key: key)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }

    @Test("The key never reaches the address or a query")
    func keyStaysOutOfTheAddress() {
        let request = MobileClient.request("ui/mobile/chat/studio", hub: hub, key: "secret-key",
                                           query: [URLQueryItem(name: "db", value: "gen-1")])
        let address = request.url?.absoluteString ?? ""
        #expect(!address.contains("secret-key"))
        #expect(address == "http://100.96.10.20:8765/ui/mobile/chat/studio?db=gen-1")
    }

    @Test("A read sends the tag of the last body, so an unchanged fleet costs one empty answer")
    func theReadSendsItsTag() {
        let first = MobileClient.snapshotRequest(hub: hub, key: nil, database: nil, etag: nil)
        #expect(first.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(first.url?.query == nil)
        let next = MobileClient.snapshotRequest(hub: hub, key: "a-key", database: "gen-1", etag: "\"abc\"")
        #expect(next.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
        #expect(next.url?.query == "db=gen-1")
        #expect(next.value(forHTTPHeaderField: "Authorization") == "Bearer a-key")
    }

    /// **The read of the state says what this build draws, with this phone's own key only** (owner API 1.285,
    /// `X-Fleet-Draws`): the hub puts pictures on a request only while each app of the owner's said `need_pictures`, and
    /// a device's read with no such header takes the phone's word back. A phone with no key of its own (the simulator)
    /// reads with the Mac's owner key, so its header would be the word of the owner's computer. The bugs that this
    /// stops: the build draws pictures and the hub never learns it; or the simulator says it for a Mac that does not
    /// draw them, and the hub raises pictures that the Mac shows as words.
    @Test("the state read says that this build draws pictures as options, only with this phone's own key")
    func theReadSaysWhatThisBuildDraws() {
        for etag in [nil, "\"abc\""] {
            let keyed = MobileClient.snapshotRequest(hub: hub, key: "a-key", database: "gen-1", etag: etag)
            #expect(keyed.value(forHTTPHeaderField: "X-Fleet-Draws") == "need_pictures")
            for key in [nil, ""] as [String?] {
                let unkeyed = MobileClient.snapshotRequest(hub: hub, key: key, database: "gen-1", etag: etag)
                #expect(unkeyed.value(forHTTPHeaderField: "X-Fleet-Draws") == nil)
            }
        }
    }

    @Test("Each refusal of this device says something different and names a next step")
    func eachRefusalHasItsOwnWords() {
        let reasons = ["device_not_enrolled", "device_key_required", "device_key_mismatch", "device_not_allowed",
                       "key_not_expected"]
        let words = reasons.map(MobileError.authWords)
        #expect(Set(words).count == reasons.count)
        #expect(words.allSatisfy { !$0.isEmpty })
        // A reason that this app does not know still reaches the owner, with the hub's own word in it.
        #expect(MobileError.authWords("something_new").contains("something_new"))
    }

    @Test("A 403 keeps the hub's auth reason, so the right words show")
    func refusalCarriesTheAuthReason() throws {
        let body = #"{"error": "device key does not match", "auth": "device_key_mismatch"}"#.data(using: .utf8)!
        let response = HTTPURLResponse(url: hub, statusCode: 403, httpVersion: nil, headerFields: nil)!
        #expect(throws: MobileError.self) { try MobileClient.check(response, data: body) }
        do { _ = try MobileClient.check(response, data: body) }
        catch let error as MobileError {
            #expect(error.auth == "device_key_mismatch")
            #expect(error.isDefinitive)
            #expect(error.errorDescription == MobileError.authWords("device_key_mismatch"))
        }
    }

    @Test("A refusal without a body still refuses, with its status")
    func refusalWithoutABody() {
        let response = HTTPURLResponse(url: hub, statusCode: 500, httpVersion: nil, headerFields: nil)!
        do {
            _ = try MobileClient.check(response, data: Data())
            Issue.record("A 500 must not read as an answer.")
        } catch let error as MobileError {
            #expect(error.auth == nil)
            // A 500 may still arrive later, so it never ends a request that waits.
            #expect(!error.isDefinitive)
        } catch { Issue.record("Another error: \(error)") }
    }

    @Test("200 brings a body and 304 says that nothing changed")
    func bodyOrNotModified() throws {
        let ok = HTTPURLResponse(url: hub, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let same = HTTPURLResponse(url: hub, statusCode: 304, httpVersion: nil, headerFields: nil)!
        #expect(try MobileClient.check(ok, data: Data("{}".utf8)))
        #expect(try MobileClient.check(same, data: Data()) == false)
    }

    @Test("A code is eight characters of the hub's own alphabet")
    func codesAreCheckedBeforeTheySend() {
        #expect(MobileClient.normalizedCode("abcd-2345") == "ABCD2345")
        #expect(MobileClient.normalizedCode(" ABCD 2345 ") == "ABCD2345")
        #expect(MobileClient.normalizedCode("ABCD234") == nil)
        #expect(MobileClient.normalizedCode("ABCD23456") == nil)
        // The alphabet leaves out the characters that look alike, so a code never holds I, O, 0 or 1.
        for confusing in ["ABCDI234", "ABCDO234", "ABCD0234", "ABCD1234"] {
            #expect(MobileClient.normalizedCode(confusing) == nil)
        }
        #expect(MobileClient.normalizedCode("") == nil)
    }

    @Test("The two refusals of an enrollment ask for different steps")
    func enrollmentRefusals() {
        let notADevice = MobileError.refusal(
            HubRefusal(status: 403, hubWords: "127.0.0.1 is not an owner device. See \"owner_devices\" in team.json."), auth: nil)
        let wrongCode = MobileError.refusal(HubRefusal(status: 403, hubWords: "that code is not valid"), auth: nil)
        let tooMany = MobileError.refusal(
            HubRefusal(status: 429, hubWords: "too many wrong codes; wait an hour, then make a new code"), auth: nil)
        #expect(MobileError.enrollWords(notADevice) != MobileError.enrollWords(wrongCode))
        #expect(MobileError.enrollWords(notADevice).contains("does not know this phone"))
        #expect(MobileError.enrollWords(notADevice).contains("Mac"))
        #expect(MobileError.enrollWords(wrongCode).contains("did not work"))
        #expect(MobileError.enrollWords(tooMany).contains("hour"))
        // Twelve words at most, each (T-35): the first had 24.
        for refusal in [notADevice, wrongCode, tooMany] {
            #expect(MobileError.enrollWords(refusal).split(separator: " ").count <= 12)
        }
        // The hub's own words come through for anything else, so no refusal is ever silent.
        #expect(!MobileError.enrollWords(.noAnswer).isEmpty)
    }

    @Test("A hub without the phone's routes says so in its own words")
    func aHubFromBeforeTheRoutes() {
        let words = MobileError.noPhoneRoutes.errorDescription ?? ""
        #expect(words.contains("phone's routes"))
        // It is the hub that is old, so reading again changes nothing.
        #expect(MobileError.noPhoneRoutes.isDefinitive)
        #expect(MobileError.noPhoneRoutes.auth == nil)
        // It never reads as one of the refusals of this device's key.
        #expect(words != MobileError.authWords("device_not_enrolled"))
    }

    @Test("A refusal that the hub decided ends a request; one that may still arrive does not")
    func definitiveRefusals() {
        for status in [400, 403, 404, 409, 413, 415, 422, 429, 503] {
            #expect(MobileError.refusal(HubRefusal(status: status, hubWords: ""), auth: nil).isDefinitive)
        }
        for status in [500, 502, 504] {
            #expect(!MobileError.refusal(HubRefusal(status: status, hubWords: ""), auth: nil).isDefinitive)
        }
        #expect(!MobileError.noAnswer.isDefinitive)
    }
}

/// The keychain itself. These run one at a time, because they share the one key of this phone: two of them at once
/// would read a key that the other just wrote.
@Suite("The keychain", .serialized)
struct DeviceKeyTests {
    /// An item of the checks' own: the app's own key, on an enrolled phone or a capture's simulator, is never touched.
    static let account = "device-key-check"

    @Test("The keychain takes the key, says that it has one, and gives it back")
    func theKeychainHoldsTheKey() throws {
        let holder = DeviceKey(account: Self.account)
        try holder.remove()
        #expect(!holder.has)
        try holder.save("a-key-of-256-bits")
        #expect(holder.has)
        // A second key takes the place of the first: enrolling again replaces what this phone had.
        try holder.save("another-key")
        #expect(holder.has)
        try holder.remove()
        #expect(!holder.has)
    }

    @Test("An empty keychain gives no key and asks for nothing")
    func noKeyNoPrompt() async throws {
        let holder = DeviceKey(account: Self.account)
        try holder.remove()
        #expect(try await holder.key(reason: "A check, which must not ask the owner for anything.") == nil)
    }

    @Test("An empty key is never saved")
    func emptyKeysAreRefused() {
        #expect(throws: (any Error).self) { try DeviceKey(account: Self.account).save("") }
    }

    @Test("A press on a ping reads the same key with no prompt, and loses it with the key")
    func thePressCopyFollowsTheKey() throws {
        let holder = DeviceKey(account: Self.account)
        try holder.remove()
        #expect(try holder.pressKey() == nil)
        try holder.save("a-key-of-256-bits")
        #expect(try holder.pressKey() == "a-key-of-256-bits")
        // Enrolling again replaces both copies.
        try holder.save("another-key")
        #expect(try holder.pressKey() == "another-key")
        try holder.remove()
        #expect(try holder.pressKey() == nil)
    }
}

/// A press on an answer button of a ping (`PushNotifications.swift`).
@Suite("A press on a ping")
struct NeedPressTests {
    @Test("Only an answer button names an option")
    func onlyAnswerButtonsAreChoices() {
        #expect(NeedPress.choice("choice-0") == 0)
        #expect(NeedPress.choice("choice-5") == 5)
        for other in ["choice-", "choice--1", "choice-x", UNNotificationDefaultActionIdentifier,
                      UNNotificationDismissActionIdentifier] {
            #expect(NeedPress.choice(other) == nil)
        }
    }

    /// **A ping's button that only the Mac's step stands behind is not sent** (`NeedPress.refuses`): the first option
    /// of a card that makes a GitHub App or opens the Add device picture, as Run it once of the door's card of a run;
    /// "Not now" of those cards and the options of any other card go. The bug that this stops: a press on the lock
    /// screen answered the card, the hub closed it, and nothing made the App or opened the picture.
    @Test("A ping's first option of a GitHub App's or an Add device card is not sent, and their other option is")
    func aPingsMacStepIsNotSent() throws {
        func card(_ fields: [String: Any]) throws -> OwnerNeed {
            let base: [String: Any] = ["id": 7, "by": "manager", "title": "Make the shop's own GitHub App in acme",
                                       "why": "The door holds no way in yet.", "raised": 20, "todo": "",
                                       "options": ["Make the App", "Not now"]]
            return try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(
                withJSONObject: base.merging(fields) { _, new in new }))
        }
        let app = try card(["github_app": "acme"])
        let scan = try card(["add_device": 1, "options": ["Scan it again", "Not now"]])
        let plain = try card([:])
        #expect(NeedPress.refuses(app, choice: 0) && NeedPress.refuses(scan, choice: 0))
        #expect(!NeedPress.refuses(app, choice: 1) && !NeedPress.refuses(scan, choice: 1))
        #expect(!NeedPress.refuses(plain, choice: 0) && !NeedPress.refuses(plain, choice: 1))
        let door = try card(["door_host": "web-1", "options": ["Run it once", "Full access on web-1", "No"]])
        #expect(NeedPress.refuses(door, choice: 0) && !NeedPress.refuses(door, choice: 2))
    }

    @Test("Each refusal says why the answer did not go, in its own words")
    func eachRefusalHasItsOwnWords() {
        let answered = NeedPress.words(MobileError.refusal(HubRefusal(status: 409, hubWords: "owner request is already answered"),
                                                           auth: nil), need: 7)
        let changed = NeedPress.words(MobileError.refusal(
            HubRefusal(status: 409, hubWords: "hub generation changed; refresh state before sending"), auth: nil), need: 7)
        let gone = NeedPress.words(MobileError.refusal(HubRefusal(status: 404, hubWords: "owner request does not exist"),
                                                       auth: nil), need: 7)
        let silent = NeedPress.words(MobileError.noAnswer, need: 7)
        // The words name no number of the hub's (fix round 3, item 47): the title names the agent.
        #expect(answered == "Already answered.")
        #expect(![answered, changed, gone, silent].contains { $0.contains("N-7") })
        #expect(changed.contains("records changed"))
        #expect(gone.contains("no longer"))
        #expect(silent.contains("did not answer"))
        #expect(Set([answered, changed, gone, silent]).count == 4)
        // A refusal of this phone's key names the step, as everywhere else in the app.
        #expect(NeedPress.words(MobileError.refusal(HubRefusal(status: 403, hubWords: ""), auth: "device_key_mismatch"), need: 7)
                == MobileError.authWords("device_key_mismatch"))
    }

    @Test("The delegate's press handler, called off the main thread, runs its work and then iOS's completion on it")
    @MainActor
    func theDelegateCompletesOnTheMainThread() async throws {
        // iOS calls the press's delegate off the main thread; UIKit's snapshot that follows the completion asserts the
        // main thread, and the app aborted after every press (fix round 2, item 102). This calls the delegate method
        // itself (review B15): its `async` form fails here. The response is a tap on a ping, which opens Needs you:
        // no answer, no network.
        let delegate = PushDelegate()
        let response = try Self.response(action: UNNotificationDefaultActionIdentifier, info: ["need": 7])
        // Through the protocol, as iOS calls it, so the check reaches whichever form the delegate has.
        nonisolated(unsafe) let handler: any UNUserNotificationCenterDelegate = delegate
        nonisolated(unsafe) let pressed = response
        let main: Bool = await withCheckedContinuation { done in
            Task.detached {
                handler.userNotificationCenter?(UNUserNotificationCenter.current(), didReceive: pressed) {
                    done.resume(returning: Thread.isMainThread)
                }
            }
        }
        #expect(main)
        // The work ran before the completion: the tap opened Needs you.
        #expect(delegate.openNeeds)
    }

    /// A ping's response as iOS hands it over: the system makes it, so a check builds it from a coder of its own.
    private static func response(action: String, info: [AnyHashable: Any]) throws -> UNNotificationResponse {
        let content = UNMutableNotificationContent()
        content.userInfo = info
        let request = UNNotificationRequest(identifier: "ping", content: content, trigger: nil)
        return try #require(UNNotificationResponse(coder: PingCoder(request: request, action: action)))
    }
}

/// The fields of a notification and of its response, as the system's own decoders ask for them.
private final class PingCoder: NSCoder {
    let request: UNNotificationRequest
    let action: String
    init(request: UNNotificationRequest, action: String) {
        self.request = request
        self.action = action
    }
    override var allowsKeyedCoding: Bool { true }
    override func containsValue(forKey key: String) -> Bool { decodeObject(forKey: key) != nil }
    override func decodeObject(forKey key: String) -> Any? {
        switch key {
        case "request": request
        case "date": Date()
        case "notification": UNNotification(coder: self)
        case "actionIdentifier": action
        case "sourceIdentifier", "originIdentifier", "targetSceneIdentifier": "ping"
        default: nil
        }
    }
    override func decodeBool(forKey key: String) -> Bool { false }
    override func decodeInteger(forKey key: String) -> Int { 0 }
    override func decodeInt64(forKey key: String) -> Int64 { 0 }
    override func decodeDouble(forKey key: String) -> Double { 0 }
}

/// A sealed ping (`UI-API.md` version 1.76): what the hub seals with this phone's key, the notification service
/// extension opens. The bytes below are the ones the hub's own test (`test_push.Seal`) seals for the same key and nonce,
/// so the two sides hold one format.
@Suite("A sealed ping", .serialized)
struct SealedPingTests {
    static let key = Data((0x80...0x9f).map { UInt8($0) })
    static let sealed = """
        070000004041424344454647e4598b326584628037afee8216c82adca4b3fc5e7b754eaab5eff0e334f662c72fedae18d8e13042dfb2c6\
        2f9baf72da463e825e814b416d04c6a7f533882a6bcf85f1697521d7cd8e48f2e120030c1cace173f7b0816e915389c3c5486683947edf\
        dee6cc4b7f97e36ed7379089ca005b577823ba5a02bec11e17d980c3dd101c8013335ba4ef822b00472c733e6b36ec3a874059fab52fff\
        4b4481b67e
        """
    /// API 1.245: a door card's part, with `no_button` [1] (Full access), as the hub's `push.seal` seals it for the same
    /// key and nonce.
    static let doorSealed = """
        070000004041424344454647e4598b326584628037b0fa9516ee64cbe1b2e7507d211dbdafe3a0f375ed6d8539fba9159db17c079abed0\
        2dc0f962d94737865b885e557601c6a7e333d67e3c9893fe6d7635ccc28335bcb63a120616ace11af5c18f238e5794c5c455379bf507a4\
        e9e08e4b6486b075d8268189ca00534d606fee540fb4c30510dbb281df13109652675bb2ef8d304e7b7373371957acec367c3999943694\
        64f7d32cec14f20df0efab684796afcef3a2a4
        """
    static let account = "seal-key-check"

    static func bytes(_ hex: String) -> Data {
        var data = Data()
        var at = hex.startIndex
        while at < hex.endIndex {
            let next = hex.index(at, offsetBy: 2)
            data.append(UInt8(hex[at..<next], radix: 16)!)
            at = next
        }
        return data
    }

    static func ping(_ sealed: Data) -> [AnyHashable: Any] {
        ["need": 23, "db": "0123456789ab", "sealed": sealed.base64EncodedString(),
         "aps": ["alert": ["title": "Needs you"], "mutable-content": 1]]
    }

    @Test("The phone opens what the hub sealed: the agent, the title and the buttons")
    func opensTheHubsSeal() {
        let said = SealedPing.open(Self.ping(Self.bytes(Self.sealed)), key: Self.key)
        #expect(said == SealedPing(need: 23, db: "0123456789ab", title: "Atlas",
                                   body: "May I restart the database tonight at 23:00?",
                                   options: ["Yes, restart", "Not tonight"]))
    }

    @Test("A changed byte, another key or no sealed part opens nothing, and the banner stays as it came")
    func nothingElseOpens() {
        var changed = Self.bytes(Self.sealed)
        changed[20] ^= 1
        #expect(SealedPing.open(Self.ping(changed), key: Self.key) == nil)
        #expect(SealedPing.open(Self.ping(Self.bytes(Self.sealed)), key: Data(count: 32)) == nil)
        #expect(SealedPing.open(Self.ping(Self.bytes(Self.sealed)), key: nil) == nil)
        #expect(SealedPing.open(["need": 23, "aps": ["alert": ["title": "Needs you"]]], key: Self.key) == nil)
    }

    @Test("The extension shows what the sealed part says, and leaves a part that does not open as it came")
    func theBannerShowsWhatThePingSays() {
        let content = UNMutableNotificationContent()
        content.title = "Needs you"
        content.userInfo = Self.ping(Self.bytes(Self.sealed))
        #expect(SealedPing.show(in: content, key: Self.key))
        #expect(content.title == "Atlas")
        #expect(content.body == "May I restart the database tonight at 23:00?")
        #expect(content.categoryIdentifier == "need")
        #expect(content.userInfo["options"] as? [String] == ["Yes, restart", "Not tonight"])
        #expect((content.userInfo["need"] as? NSNumber)?.intValue == 23)
        #expect(content.userInfo["sealed"] == nil)
        let closed = UNMutableNotificationContent()
        closed.title = "Needs you"
        closed.userInfo = Self.ping(Self.bytes(Self.sealed))
        #expect(!SealedPing.show(in: closed, key: Data(count: 32)))
        #expect(closed.title == "Needs you" && closed.body.isEmpty && closed.categoryIdentifier.isEmpty)
    }

    /// Full access on a door card counts only with the owner key on the Mac, so its ping names it in `no_button`, and
    /// `NeedActions` draws no button for it while Run it once and No keep their index. Bug: the field is lost on its way
    /// to the extension, and the lock screen offers a button whose press the hub refuses.
    @Test("A door card's ping names the option that gets no button, and the extension's fields carry it")
    func aDoorPingNamesFullAccessAsNoButton() {
        let said = SealedPing.open(Self.ping(Self.bytes(Self.doorSealed)), key: Self.key)
        #expect(said == SealedPing(need: 24, db: "0123456789ab", title: "Atlas", body: "Run one root script on web-1?",
                                   options: ["Run it once", "Full access on web-1", "No"], noButton: [1]))
        let content = UNMutableNotificationContent()
        content.userInfo = Self.ping(Self.bytes(Self.doorSealed))
        #expect(SealedPing.show(in: content, key: Self.key))
        #expect(content.userInfo["no_button"] as? [Int] == [1])
        #expect(content.userInfo["options"] as? [String] == ["Run it once", "Full access on web-1", "No"])
        let older = UNMutableNotificationContent()              // a ping that names none puts none in the fields
        older.userInfo = Self.ping(Self.bytes(Self.sealed))
        #expect(SealedPing.show(in: older, key: Self.key) && older.userInfo["no_button"] == nil)
    }

    @Test("The phone makes its seal key once and keeps it for the extension")
    func theKeyIsMadeOnce() {
        let holder = SealKey(account: Self.account)
        holder.remove()
        #expect(holder.read() == nil)
        let made = holder.current()
        #expect(made?.count == 32)
        #expect(holder.current() == made)
        #expect(holder.read() == made)
        holder.remove()
        #expect(holder.read() == nil)
    }

    @Test("The push token goes with the seal key in base64 only when the hub seals")
    func theTokenCarriesTheKey() throws {
        let token = String(repeating: "ab", count: 32)
        let sealed = try JSONSerialization.jsonObject(
            with: MobileClient.pushTokenBody(token, environment: "production", seal: Self.key, database: "g")) as? [String: Any]
        #expect(sealed?["seal"] as? String == Self.key.base64EncodedString())
        #expect(sealed?["token"] as? String == token)
        let plain = try JSONSerialization.jsonObject(
            with: MobileClient.pushTokenBody(token, environment: "production", seal: nil, database: "g")) as? [String: Any]
        #expect(plain?["seal"] == nil)
    }
}

/// **A ping to a member's phone** (B9, b9-phone-members.md section 5 and 10.10): the hub's own vectors
/// (`app/vectors/agent-sharing-vectors.json`, `member`, made by `teams_links.member_ping`), opened with the key of the
/// link that they belong to on a phone that holds several companies, drawn with the approved words and no button, and
/// tapped into the chat of that link by the phone's own record of it.
@Suite("A member's ping", .serialized)
struct MemberPingTests {
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("vectors").appendingPathComponent("agent-sharing-vectors.json")
    static let costa = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!
    static let garcia = UUID(uuidString: "9B1DEB4D-3B7D-4BAD-9BDD-2B0D7B3DCB6D")!
    static let service = "com.founderizer.mobile.link-seal-check"

    struct Records: MemberLinkRecords {
        let held: [UUID: MemberLinkRecord]
        func memberLink(_ link: UUID) -> MemberLinkRecord? { held[link] }
    }

    static let records = Records(held: [costa: MemberLinkRecord(company: "Costa Studio", chats: ["atlas", "sales"]),
                                        garcia: MemberLinkRecord(company: "García SL", chats: ["atlas"])])

    static func member() throws -> [String: Any] {
        let data = try Data(contentsOf: file)
        let vectors = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(vectors["member"] as? [String: Any])
    }

    static func payload(_ json: Any?) throws -> [AnyHashable: Any] {
        let text = try #require(json as? String)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [AnyHashable: Any])
    }

    /// The vectors' member ping, and its form with a `need`, options and a title in the part.
    static func pings() throws -> [[AnyHashable: Any]] {
        let member = try member()
        let withNeed = try #require(member["with_need"] as? [String: Any])
        let form = try #require(withNeed["member_form"] as? [String: Any])
        return [try payload(member["payload_json"]), try payload(form["payload_json"])]
    }

    /// The phone's keys: Costa Studio's link holds the vectors' key, García SL's link the vectors' other link's key.
    static func seals() throws -> [LinkSeal] {
        let member = try member()
        return [LinkSeal(link: costa, key: SealedPingTests.bytes(try #require(member["seal_key"] as? String))),
                LinkSeal(link: garcia, key: SealedPingTests.bytes(try #require(member["another_seal_key"] as? String)))]
    }

    /// A member ping whose part a hub sealed with `key`: `said`, padded with spaces as the hub pads it.
    static func ping(_ said: [String: Any], key: Data) throws -> [AnyHashable: Any] {
        var plain = try JSONSerialization.data(withJSONObject: said, options: [.sortedKeys])
        plain.append(contentsOf: [UInt8](repeating: 0x20, count: (256 - plain.count % 256) % 256))
        let sealed = try ChaChaPoly.seal(plain, using: SymmetricKey(data: key)).combined
        return ["aps": ["alert": ["loc-key": "shared-reply"], "mutable-content": 1], "sealed": sealed.base64EncodedString()]
    }

    /// What `NeedSeal` shows; `body` is what iOS drew from the `loc-key` before the extension ran (none here).
    static func drawn(_ info: [AnyHashable: Any], ownerKey: Data? = nil, body: String = "") -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.userInfo = info
        content.body = body
        SealedPing.showByForm(in: content) { ownerKey }
        return content
    }

    /// Bug: the phone's word or form is not the hub's (a `loc-key` of its own, the pad read as part of the JSON), and a
    /// member's phone opens none of its company's pings; or the extension carries a part's `need` and options to the
    /// banner, whose button would answer as the owner.
    @Test("Each member ping of the vectors opens with its link's key, and shows the approved words with no button")
    func theVectorsOpenWithTheirLinksKey() throws {
        let seals = try Self.seals()
        for info in try Self.pings() {
            #expect(PingForm.of(info) == .member)
            #expect(MemberPing.open(info, seals: seals) == MemberPing(link: Self.costa, agent: "atlas"))
            let content = Self.drawn(info, ownerKey: Data(repeating: 7, count: 32))
            #expect(content.title.isEmpty && content.subtitle.isEmpty)
            #expect(content.body == "New reply in a shared chat")
            #expect(content.categoryIdentifier.isEmpty)
            for field in ["need", "db", "options", "no_button", "title"] { #expect(content.userInfo[field] == nil) }
            #expect(content.userInfo["sealed"] as? String == info["sealed"] as? String)
        }
    }

    /// Bug: the loc-key's English is missing from the app's table (iOS then shows "shared-reply" on the lock screen), or
    /// its Spanish is not the approved one; or `NeedSeal` has no table, and its words are English on a Spanish phone.
    @Test("The app's and NeedSeal's tables give the approved words for the vectors' loc-key, in English and in Spanish")
    func theTableHasTheApprovedWords() throws {
        let pings = try Self.pings()
        let aps = try #require(pings[0]["aps"] as? [String: Any])
        let word = try #require((aps["alert"] as? [String: Any])?["loc-key"] as? String)
        #expect(word == PingForm.memberWord)
        let extensionURL = try #require(Bundle.main.builtInPlugInsURL).appendingPathComponent("NeedSeal.appex")
        let needSeal = try #require(Bundle(url: extensionURL))
        for bundle in [Bundle.main, needSeal] {
            func words(_ language: String) throws -> String {
                let path = try #require(bundle.path(forResource: language, ofType: "lproj"))
                return try #require(Bundle(path: path)).localizedString(forKey: word, value: "missing", table: "Localizable")
            }
            #expect(try words("en") == "New reply in a shared chat")
            #expect(try words("es") == "Nueva respuesta en un chat compartido")
        }
    }

    /// Bug: `NeedSeal` writes its own words over the ones that iOS drew in the phone's language, so a Spanish phone shows
    /// another text than the approved Spanish.
    @Test("The words that iOS drew for a member ping stay, in any language")
    func theWordsThatIOSDrewStay() throws {
        for info in try Self.pings() {
            let content = Self.drawn(info, body: "Nueva respuesta en un chat compartido")
            #expect(content.body == "Nueva respuesta en un chat compartido")
        }
    }

    /// Bug: the phone takes a member ping with a badge, which no hub may set on a member's icon, or with another sound
    /// than the platform's member route sends (b9-phone-members.md 10.7; the platform's `MEMBER_APS`).
    @Test("A member ping with a badge or another sound than the default is no member ping")
    func aBadgeIsNoMemberPing() throws {
        let info = try Self.pings()[0]
        let aps = try #require(info["aps"] as? [String: Any])
        func with(_ extra: [String: Any]) -> [AnyHashable: Any] {
            var changed = info
            changed["aps"] = aps.merging(extra) { _, new in new }
            return changed
        }
        #expect(PingForm.of(with(["sound": "default"])) == .member)
        #expect(PingForm.of(with(["badge": 3])) == .other)
        #expect(PingForm.of(with(["sound": "default", "badge": 0])) == .other)
        #expect(PingForm.of(with(["sound": "alarm.caf"])) == .other)
        #expect(MemberPing.open(with(["badge": 3]), seals: try Self.seals()) == nil)
    }

    /// Bug: the first key that opens a part names its company. ChaChaPoly commits to no key, and a phone whose links
    /// share one key (each link must make its own) would open every company's ping as the first company's.
    @Test("A ping for another link's key opens nothing, and a part that two links' keys open names no company")
    func anotherLinksKeyOpensNothing() throws {
        let seals = try Self.seals()
        for info in try Self.pings() {
            #expect(MemberPing.open(info, seals: [seals[1]]) == nil)
            #expect(MemberPing.route(info, seals: [seals[1]], records: Self.records) == .chats)
            #expect(MemberPing.open(info, seals: []) == nil)
            let shared = [seals[0], LinkSeal(link: Self.garcia, key: seals[0].key)]
            #expect(MemberPing.open(info, seals: shared) == nil)
            #expect(MemberPing.route(info, seals: shared, records: Self.records) == .chats)
        }
    }

    /// Bug: the extension tries the link keys on every sealed ping, so the owner's form, which only his hub sends, is
    /// read as a company's.
    @Test("The owner's form opens with the owner's key as before, and never with a link's key")
    func theOwnersFormIsUnchanged() throws {
        let owner = SealedPingTests.ping(SealedPingTests.bytes(SealedPingTests.sealed))
        #expect(PingForm.of(owner) == .owner)
        let content = Self.drawn(owner, ownerKey: SealedPingTests.key)
        #expect(content.title == "Atlas" && content.categoryIdentifier == "need")
        #expect(content.userInfo["options"] as? [String] == ["Yes, restart", "Not tonight"])
        let withNeed = try #require(try Self.member()["with_need"] as? [String: Any])
        let linkSealed = try Self.payload((withNeed["owner_form"] as? [String: Any])?["payload_json"])
        let seals = try Self.seals()
        #expect(PingForm.of(linkSealed) == .owner)
        #expect(MemberPing.open(linkSealed, seals: seals) == nil)
        #expect(MemberPing.route(linkSealed, seals: seals, records: Self.records) == nil)
        let closed = Self.drawn(linkSealed, ownerKey: SealedPingTests.key)
        #expect(closed.title.isEmpty && closed.categoryIdentifier.isEmpty && closed.userInfo["sealed"] != nil)
    }

    /// Bug: the extension gives a member ping to the owner's opener, and a part in the owner's layout, sealed with a key
    /// that the owner's opener holds, gets his banner and buttons on a member's notification.
    @Test("A member ping never opens with the owner's key, and gets its own words with no button")
    func theOwnersKeyNeverOpensAMemberPing() throws {
        // the owner's own sealed part, which his key opens, in a member ping's open part
        let info: [AnyHashable: Any] = ["aps": ["alert": ["loc-key": "shared-reply"], "mutable-content": 1],
                                        "sealed": SealedPingTests.bytes(SealedPingTests.sealed).base64EncodedString()]
        #expect(PingForm.of(info) == .member)
        #expect(SealedPing.open(info, key: SealedPingTests.key) == nil)
        let content = Self.drawn(info, ownerKey: SealedPingTests.key)
        #expect(content.title.isEmpty && content.body == "New reply in a shared chat")
        #expect(content.categoryIdentifier.isEmpty && content.userInfo["need"] == nil && content.userInfo["options"] == nil)
        var other = info                    // a key that the member form does not have is no member ping
        other["need"] = 23
        #expect(PingForm.of(other) != .member)
        var titled = info
        titled["aps"] = ["alert": ["loc-key": "shared-reply", "title": "Your bank"], "mutable-content": 1]
        #expect(PingForm.of(titled) == .other && MemberPing.route(titled, seals: [], records: nil) == nil)
    }

    /// Bug: the phone takes the chat's company or link from the part, which the company's hub writes, and not from its
    /// own record of the link whose key opened it; or it opens a chat that the link does not have.
    @Test("A tap opens the chat of the link whose key opened the part, with that link's company from the phone's record")
    func theCompanyComesFromThePhonesRecord() throws {
        let seals = try Self.seals()
        let lying: [String: Any] = ["t": "news", "agent": "atlas", "n": 5, "company": "Other Co",
                                    "link": Self.garcia.uuidString.lowercased(), "name": "Ana"]
        let info = try Self.ping(lying, key: seals[0].key)
        #expect(MemberPing.route(info, seals: seals, records: Self.records)
                == .chat(link: Self.costa, company: "Costa Studio", agent: "atlas"))
        let elsewhere = try Self.ping(["t": "news", "agent": "orion", "n": 5], key: seals[0].key)
        #expect(MemberPing.route(elsewhere, seals: seals, records: Self.records) == .chats)
        #expect(MemberPing.route(info, seals: seals, records: Records(held: [:])) == .chats)
        #expect(MemberPing.route(info, seals: seals, records: nil) == .chats)
    }

    /// Bug: the delegate's branch by form is wrong, so a member ping reaches Needs you or the owner's press, or an
    /// owner's ping is read as a member's; or a dismiss also opens a chat at the next start. Through `received`, the one
    /// function that iOS's `didReceive` calls.
    @Test("Only a tap on a member ping opens its chat, and it opens nothing of the owner's")
    @MainActor
    func aTapOpensTheChat() async throws {
        let delegate = PushDelegate()
        delegate.memberLinks = Self.records
        let info = try Self.pings()[0]
        let seals = try Self.seals()
        await delegate.received(info, action: UNNotificationDismissActionIdentifier, agent: "") { seals }
        #expect(delegate.memberTap == nil && delegate.takeMemberRoute() == nil)
        await delegate.received(info, action: UNNotificationDefaultActionIdentifier, agent: "") { seals }
        #expect(!delegate.openNeeds)
        #expect(delegate.takeMemberRoute() == .chat(link: Self.costa, company: "Costa Studio", agent: "atlas"))
        #expect(delegate.takeMemberRoute() == nil)          // once
        await delegate.received(["need": 7], action: UNNotificationDefaultActionIdentifier, agent: "") { seals }
        #expect(delegate.openNeeds && delegate.memberTap == nil)
    }

    /// Bug: the route is found at the tap with the record of that moment; on a cold start the store and its record come
    /// after the tap, so the usual tap opens Chats and not its chat.
    @Test("A tap before the phone's record is there opens its chat once the record is there")
    @MainActor
    func aColdStartTapFindsItsChat() async throws {
        let delegate = PushDelegate()
        let seals = try Self.seals()
        let info = try Self.pings()[0]
        await delegate.received(info, action: UNNotificationDefaultActionIdentifier, agent: "") { seals }
        delegate.memberLinks = Self.records
        #expect(delegate.takeMemberRoute() == .chat(link: Self.costa, company: "Costa Studio", agent: "atlas"))
        await delegate.received(info, action: UNNotificationDefaultActionIdentifier, agent: "") { seals }
        delegate.memberLinks = Records(held: [Self.garcia: MemberLinkRecord(company: "García SL", chats: ["atlas"])])
        #expect(delegate.takeMemberRoute() == .chats)       // its link is no longer active
    }

    /// Bug: a link's key is readable before the first unlock, goes into a backup to another phone, or syncs to the
    /// person's other devices through iCloud Keychain.
    @Test("A link's seal key is kept after first unlock, on this phone only, and never synced")
    func aLinksKeyStaysOnThisPhone() throws {
        let keys = LinkSealKeys(service: Self.service)
        defer { keys.remove(Self.costa) }
        keys.remove(Self.costa)
        _ = try #require(keys.make(Self.costa))
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.service,
                                    kSecAttrAccount as String: LinkSealKeys.account(Self.costa),
                                    kSecAttrAccessGroup as String: SealKey.group,
                                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                                    kSecReturnAttributes as String: true]
        var found: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess)
        let item = try #require(found as? [String: Any])
        #expect(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect((item[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue != true)
    }

    /// Bug: the links' keys are one keychain item (as the owner's one `SealKey`), so every company gets the same key; or
    /// the owner's key is among them; or `device` gives the key in standard base64, which the hub's `unb64u` refuses.
    @Test("Each link makes its own seal key and keeps it, the owner's key is none of them, and device gives it in b64u")
    func eachLinkHasItsOwnKey() throws {
        let keys = LinkSealKeys(service: Self.service)
        let owner = SealKey(account: "seal-key-member-check")
        defer { keys.remove(Self.costa); keys.remove(Self.garcia); owner.remove() }
        keys.remove(Self.costa)
        keys.remove(Self.garcia)
        #expect(keys.all().isEmpty && keys.read(Self.costa) == nil)
        let ownerKey = try #require(owner.current())
        let costa = try #require(keys.make(Self.costa))
        let garcia = try #require(keys.make(Self.garcia))
        #expect(costa.count == 32 && garcia.count == 32 && costa != garcia && costa != ownerKey && garcia != ownerKey)
        #expect(keys.make(Self.costa) == costa && keys.read(Self.garcia) == garcia)
        #expect(Set(keys.all().map(\.link)) == [Self.costa, Self.garcia])
        #expect(keys.all().first { $0.link == Self.costa }?.key == costa)
        keys.remove(Self.costa)
        #expect(keys.all() == [LinkSeal(link: Self.garcia, key: garcia)] && owner.read() == ownerKey)
        let vectorKey = try #require(try Self.member()["seal_key"] as? String)
        let device = try #require(try Self.deviceRequest())
        #expect(LinkSealKeys.wire(SealedPingTests.bytes(vectorKey)) == device["seal"] as? String)
    }

    /// The vectors' `device` request of a member's phone (`messages`, "device").
    static func deviceRequest() throws -> [String: Any]? {
        let data = try Data(contentsOf: file)
        let vectors = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(vectors["messages"] as? [[String: Any]])
        let json = try #require(messages.first { $0["name"] as? String == "device" }?["json"] as? String)
        return try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    }
}

/// This phone's own signing key (owner feature `door_calls`, UI-API 1.81). The simulator has no Secure Enclave, so these
/// checks hold the software key; both keep the same statement and the same signature format.
@Suite("This phone's signing key", .serialized)
struct DeviceSigningKeyTests {
    static let account = "signing-key-check"

    static func need(_ fields: String) throws -> OwnerNeed {
        try JSONDecoder().decode(OwnerNeed.self, from: Data(#"{"id": 7, "by": "manager", "title": "Allow this call?", "why": "", "todo": "", "raised": 20, "answer": null, "answered": null, "options": ["Allow it once", "No"]\#(fields)}"#.utf8))
    }

    static func verifies(_ signature: String, _ statement: String, with key: String) throws -> Bool {
        let key = try P256.Signing.PublicKey(x963Representation: try #require(Data(base64Encoded: key)))
        let signature = try P256.Signing.ECDSASignature(derRepresentation: try #require(Data(base64Encoded: signature)))
        return key.isValidSignature(signature, for: Data(statement.utf8))
    }

    @Test("The key signs what its public half verifies, a new key replaces the old one, and it goes with the phone's key")
    func signsAndGoes() throws {
        let holder = DeviceSigningKey(account: Self.account)
        try holder.remove()
        #expect(try holder.sign("a statement") == nil)
        let key = try holder.make()
        #expect(Data(base64Encoded: key)?.count == 65)
        let signature = try #require(try holder.sign("a statement"))
        #expect(try Self.verifies(signature, "a statement", with: key))
        #expect(try !Self.verifies(signature, "another statement", with: key))
        let next = try holder.make()
        #expect(next != key)
        #expect(try Self.verifies(try #require(try holder.sign("a statement")), "a statement", with: next))
        try holder.remove()
        #expect(try holder.sign("a statement") == nil)
    }

    @Test("Only the first option of an item with a door call is signed, and the statement names the fleet, item and call")
    func onlyTheYesToADoorCallIsSigned() throws {
        let holder = DeviceSigningKey(account: Self.account)
        let key = try holder.make()
        let call = String(repeating: "c", count: 64)
        let need = try Self.need(#", "door_call": "\#(call)", "door_fleet": "fleet-1""#)
        let approval = try #require(holder.approval(for: need, choice: 0))
        let said = try #require(try JSONSerialization.jsonObject(with: Data(approval.statement.utf8)) as? [String: Any])
        #expect(said["kind"] as? String == "door-call")
        #expect(said["fleet"] as? String == "fleet-1")
        #expect(said["need"] as? Int == 7)
        #expect(said["call"] as? String == call)
        #expect(try Self.verifies(approval.signature, approval.statement, with: key))
        #expect(holder.approval(for: need, choice: 1) == nil)
        #expect(holder.approval(for: try Self.need(""), choice: 0) == nil)
        #expect(holder.approval(for: try Self.need(#", "door_call": "\#(call)""#), choice: 0) == nil)
        try holder.remove()
        #expect(holder.approval(for: need, choice: 0) == nil)
    }

    /// The owner's "Show the script" (19 November 2026): on the door's card of a run the phone signs only the hash that
    /// it computed from the script that the card shows, as the Mac does. Bug: it signs the hub's hash of a script that
    /// it never showed, or of another script than the one that it shows.
    @Test("On the door's card of a run the phone signs only the hash of the script that the card shows")
    func aRunIsSignedOnlyForTheScriptThatTheCardShows() throws {
        let holder = DeviceSigningKey(account: Self.account)
        _ = try holder.make()
        let script = "systemctl reload nginx\n"
        let call = DoorCall.hash(target: "web-1", action: DoorCall.run, arguments: [], content: Data(script.utf8))
        func card(_ shown: String?) throws -> OwnerNeed {
            var fields: [String: Any] = ["id": 7, "by": "manager", "title": DoorCall.title(host: "web-1"), "why": "",
                                         "todo": "", "raised": 20, "options": DoorCall.answers(host: "web-1"),
                                         "door_call": call, "door_fleet": "fleet-1", "door_host": "web-1"]
            if let shown { fields["door_script"] = shown; fields["details"] = DoorCall.details(script: shown) }
            return try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        let approval = try #require(holder.approval(for: try card(script), choice: 0))
        let said = try #require(try JSONSerialization.jsonObject(with: Data(approval.statement.utf8)) as? [String: Any])
        #expect(said["call"] as? String == call)
        #expect(holder.approval(for: try card("systemctl stop nginx\n"), choice: 0) == nil)    // another script
        #expect(holder.approval(for: try card(nil), choice: 0) == nil)                         // no script to show
        try holder.remove()
    }
}


/// This phone's own recovery key and its copy of the recovery code (owner feature `recovery_copy`, UI-API 1.95, DevOps
/// plan V12). The simulator has no Secure Enclave, so these checks hold the software key; the box is the same.
@Suite("This phone's recovery key", .serialized)
struct DeviceRecoveryKeyTests {
    @Test("Only this phone's recovery key opens a box that the Mac sealed to it, and a new key opens no old box")
    func opensItsOwnBox() throws {
        let holder = DeviceRecoveryKey(account: "recovery-key-check")
        try holder.remove()
        #expect(!holder.exists)
        #expect(try holder.open("AAAA", device: "iphone") == nil)
        let key = try holder.make()
        #expect(holder.exists && Data(base64Encoded: key)?.count == 65)
        let code = Data("ABCD-EFGH-JKLM-NPQR-STUV-WX".utf8)
        let box = try RecoverySeal.seal(code, to: key, device: "iphone")
        #expect(try holder.open(box, device: "iphone") == code)
        #expect(throws: RecoverySeal.Failure.box) { try holder.open(box, device: "ipad") }
        _ = try holder.make()
        #expect(throws: RecoverySeal.Failure.box) { try holder.open(box, device: "iphone") }
        try holder.remove()
    }

    @Test("The copy stays on this phone, and a new enrollment takes it away")
    func theCopyIsKeptAndGoes() throws {
        let copy = RecoveryCodeCopy(account: "recovery-code-check")
        copy.remove()
        #expect(!copy.held)
        try copy.keep(Data("ABCD-EFGH-JKLM-NPQR-STUV-WX".utf8))
        #expect(copy.held)
        copy.remove()
        #expect(!copy.held)
    }
}

/// The Mac's code picture in its two forms (the owner's choice of 13 November 2026): the link of every Mac until then,
/// and the platform's link that opens this app or, on a phone without it, the App Store.
@Suite("The Mac's code link")
struct EnrollLinkTests {
    private func values(_ link: String) -> [String: String]? {
        MobileStore.enrollItems(URL(string: link)!).map { items in
            Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        }
    }

    @Test("Both forms give the same hub, code and bind")
    func bothForms() {
        let old = values("fleet://enroll?hub=http://100.96.10.20:8765&code=ABCD-EFGH&bind=b1nd")
        let new = values("https://platform.founderizer.com/enroll#hub=http://100.96.10.20:8765&code=ABCD-EFGH&bind=b1nd")
        #expect(old == ["hub": "http://100.96.10.20:8765", "code": "ABCD-EFGH", "bind": "b1nd"])
        #expect(new == old)
        // The marketing site's form, which the Macs make until most phones have this build.
        #expect(values("https://founderizer.com/enroll#hub=http://100.96.10.20:8765&code=ABCD-EFGH&bind=b1nd") == old)
        #expect(values("https://platform.founderizer.com/enroll#hub=http%3A%2F%2F100.96.10.20%3A8765&code=ABCD-EFGH")?["hub"]
                == "http://100.96.10.20:8765")
    }

    @Test("Any other link opens nothing")
    func otherLinks() {
        #expect(values("https://platform.founderizer.com/enroll") == nil)
        #expect(values("https://platform.founderizer.com/enroll#") == nil)
        #expect(values("https://platform.founderizer.com/download#code=ABCD-EFGH") == nil)
        #expect(values("https://example.com/enroll#code=ABCD-EFGH") == nil)
        #expect(values("http://platform.founderizer.com/enroll#code=ABCD-EFGH") == nil)
        #expect(values("https://www.founderizer.com/enroll#code=ABCD-EFGH") == nil)
        #expect(values("fleet://chat?code=ABCD-EFGH") == nil)
    }
}

/// **A key made and kept at once, for the checks only**: the app makes a new key in memory and writes it only after the
/// hub has taken the code (`EnrolmentKeys`; the second reader's round 4 took `make()` out of the app, because a key that
/// it writes before the hub answers is the fault of before). A check keeps one at once, as an earlier enrolment left it.
extension DeviceSigningKey {
    func make() throws -> String {
        let made = try new()
        _ = try EnrolmentKeys.moveIn(signing: (holder: self, bytes: made.bytes), recovery: nil)
        return made.publicKey
    }
}

extension DeviceRecoveryKey {
    func make() throws -> String {
        let made = try new()
        _ = try EnrolmentKeys.moveIn(signing: nil, recovery: (holder: self, bytes: made.bytes))
        return made.publicKey
    }
}
