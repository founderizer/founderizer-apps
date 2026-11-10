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
        let notADevice = MobileError.refusal(status: 403, auth: nil,
                                             message: "127.0.0.1 is not an owner device. See \"owner_devices\" in team.json.")
        let wrongCode = MobileError.refusal(status: 403, auth: nil, message: "that code is not valid")
        let tooMany = MobileError.refusal(status: 429, auth: nil,
                                          message: "too many wrong codes; wait an hour, then make a new code")
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
            #expect(MobileError.refusal(status: status, auth: nil, message: "").isDefinitive)
        }
        for status in [500, 502, 504] {
            #expect(!MobileError.refusal(status: status, auth: nil, message: "").isDefinitive)
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

    @Test("Each refusal says why the answer did not go, in its own words")
    func eachRefusalHasItsOwnWords() {
        let answered = NeedPress.words(MobileError.refusal(status: 409, auth: nil,
                                                           message: "owner request is already answered"), need: 7)
        let changed = NeedPress.words(MobileError.refusal(status: 409, auth: nil,
                                                          message: "hub generation changed; refresh state before sending"),
                                      need: 7)
        let gone = NeedPress.words(MobileError.refusal(status: 404, auth: nil, message: "owner request does not exist"),
                                   need: 7)
        let silent = NeedPress.words(MobileError.noAnswer, need: 7)
        // The words name no number of the hub's (fix round 3, item 47): the title names the agent.
        #expect(answered == "Already answered.")
        #expect(![answered, changed, gone, silent].contains { $0.contains("N-7") })
        #expect(changed.contains("records changed"))
        #expect(gone.contains("no longer"))
        #expect(silent.contains("did not answer"))
        #expect(Set([answered, changed, gone, silent]).count == 4)
        // A refusal of this phone's key names the step, as everywhere else in the app.
        #expect(NeedPress.words(MobileError.refusal(status: 403, auth: "device_key_mismatch", message: ""), need: 7)
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
