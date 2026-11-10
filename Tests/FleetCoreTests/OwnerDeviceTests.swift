import Foundation
import Testing
@testable import FleetCore

/// The owner's own devices (UI-API.md, "The owner's phone"): the reading of `GET /ui/owner/devices`, the words that
/// say whether a device ever reached the hub, the rules of the Add device form, and the two commands with their
/// receipts. A code and a key never appear in a body, a note or a saved request: only in the hub's one answer.
struct OwnerDeviceTests {
    private let hash = String(repeating: "a", count: 64)
    private let revision = String(repeating: "b", count: 40)
    private let hub = URL(string: "http://100.96.10.20:8765")!

    private func decode<T: Decodable>(_ type: T.Type, _ fields: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func request(_ command: OwnerCommand, text: String = "") -> PendingRequest {
        PendingRequest(hub: hub, database: "db", client: "local", command: command, text: text)
    }

    /// One row as `device_rows` makes it. `contacts` false: a hub from before the contact record.
    private func row(device: String = "iphone", label: String = "iPhone", address: String = "100.84.1.20",
                     key: Bool = true, since: Any = 1_000.0, lastSeen: Any = 1_500.0, contact: Any = 1_500.0,
                     answer: Any = NSNull(), codeExpires: Any = NSNull(), contacts: Bool = true) -> [String: Any] {
        var fields: [String: Any] = ["device": device, "label": label, "address": address, "key": key,
                                     "since": since, "last_seen": lastSeen, "code_expires": codeExpires,
                                     "this_device": false]
        if contacts { fields["last_contact"] = contact; fields["last_answer"] = answer }
        return fields
    }

    private func list(_ rows: [[String: Any]], db: String = "db", limit: Int = 4) -> [String: Any] {
        ["db": db, "limit": limit, "devices": rows]
    }

    @Test func theReadingIsTheHubsOwnShapeAndCarriesNoKey() throws {
        let reading = try decode(OwnerDeviceList.self, list([row(), row(device: "ipad", label: "iPad",
                                                                 address: "100.84.1.21", key: false,
                                                                 since: NSNull(), lastSeen: NSNull(),
                                                                 contact: NSNull(), codeExpires: 2_000.0)]))
        try reading.validate(database: "db")
        #expect(reading.devices.count == 2)
        let phone = reading.device("iphone")
        #expect(phone?.label == "iPhone" && phone?.key == true && phone?.since == 1_000)
        #expect(phone?.this_device == false)
        let pad = reading.device("ipad")
        #expect(pad?.key == false && pad?.openCode(now: 1_900) == 2_000 && pad?.openCode(now: 2_001) == nil)
        // Another generation, a device twice, two devices on one address and more devices than the limit are refused.
        #expect(throws: HubError.self) { try reading.validate(database: "other") }
        #expect(throws: HubError.self) { try decode(OwnerDeviceList.self, list([row(), row()])).validate(database: "db") }
        #expect(throws: HubError.self) {
            try decode(OwnerDeviceList.self, list([row(), row(device: "ipad")])).validate(database: "db")
        }
        #expect(throws: HubError.self) {
            try decode(OwnerDeviceList.self, list([row()], limit: 0)).validate(database: "db")
        }
        // A name, a label or an address that team.json cannot hold is not a reading of this route.
        #expect(throws: HubError.self) {
            try decode(OwnerDeviceList.self, list([row(device: "Phone")])).validate(database: "db")
        }
        #expect(throws: HubError.self) {
            try decode(OwnerDeviceList.self, list([row(address: "phone.local")])).validate(database: "db")
        }
    }

    @Test func oneLineSaysWhatTheDeviceIsAndWhatTheOwnerMustDo() throws {
        func words(key: Bool = false, seen: Any = NSNull(), contact: Any = NSNull(), answer: Any = NSNull(),
                   code: Any = NSNull(), contacts: Bool = true) throws -> (words: String, attention: Bool) {
            try decode(OwnerDevice.self, row(key: key, since: NSNull(), lastSeen: seen, contact: contact,
                                             answer: answer, codeExpires: code, contacts: contacts)).words(now: 2_000)
        }
        // A phone that never reached the hub reads differently from one that the hub refused. `last_seen` cannot say
        // it: the hub writes it only after the key check passes.
        #expect(try words() == ("No key yet \u{b7} it has not reached the hub", true))
        #expect(try words(contact: 1_940.0, answer: "device_not_enrolled") == ("It reached the hub 60 seconds ago, without a key.", true))
        #expect(try words(contact: 1_940.0, answer: "device_key_required") == ("It reached the hub 60 seconds ago and sent no key.", true))
        #expect(try words(key: true, contact: 1_940.0, answer: "device_key_mismatch") == ("It sent a key that is not this device's, 60 seconds ago.", true))
        #expect(try words(key: true, contact: 1_940.0, answer: "device_not_allowed") == ("It asked 60 seconds ago for a page that stays on this Mac.", false))
        // A refusal that this app does not know gets a neutral sentence, never a raw code.
        let unknown = try words(key: true, contact: 1_940.0, answer: "something_new")
        #expect(unknown.attention && !unknown.words.contains("something_new"))
        // A hub that does not report contacts never says that the device did not arrive.
        #expect(try words(contacts: false) == ("No key yet", true))
        // The key, an open code and the last read.
        #expect(try words(key: true, seen: 1_940.0, contact: 1_940.0) == ("Last read 60 seconds ago", false))
        #expect(try words(key: true, contact: 1_940.0) == ("Has its key \u{b7} no read yet", false))
        #expect(try words(code: 2_300.0) == ("A code is open \u{b7} 5 minutes left", false))
        // An expired code is no open code.
        #expect(try words(code: 1_900.0) == ("No key yet \u{b7} it has not reached the hub", true))
        #expect(OwnerDevices.left(2_600, now: 2_000) == "10 minutes left")
        #expect(OwnerDevices.left(2_040, now: 2_000) == "40 seconds left")
        #expect(OwnerDevices.left(1_999, now: 2_000) == "expired")
    }

    /// The same fact as one mark, with the sentence above behind it. The two refusals that are the hub doing its
    /// job warn instead of crossing the device, and nothing unreadable is ever drawn as a pass.
    @Test func thatOneLineIsOneMarkAndTheSentenceIsBehindIt() throws {
        func mark(key: Bool = false, seen: Any = NSNull(), contact: Any = NSNull(), answer: Any = NSNull(),
                  code: Any = NSNull()) throws -> (state: MarkState, words: String, detail: String) {
            try decode(OwnerDevice.self, row(key: key, since: NSNull(), lastSeen: seen, contact: contact,
                                             answer: answer, codeExpires: code)).mark(now: 2_000)
        }
        #expect(try mark(key: true, seen: 1_940.0, contact: 1_940.0).state == .good)
        #expect(try mark(key: true, contact: 1_940.0).words == "Has its key")
        #expect(try mark().state == .bad)
        #expect(try mark(code: 2_300.0).state == .working)
        #expect(try mark(key: true, contact: 1_940.0, answer: "device_key_mismatch").state == .bad)
        // The hub keeping one page on this Mac is not a failure of the phone.
        #expect(try mark(key: true, contact: 1_940.0, answer: "device_not_allowed").state == .warn)
        #expect(try mark(key: true, contact: 1_940.0, answer: "key_not_expected").state == .warn)
        // A refusal this app does not know is a cross, and the sentence behind it never carries the raw code.
        let unknown = try mark(key: true, contact: 1_940.0, answer: "something_new")
        #expect(unknown.state == .bad && !unknown.detail.contains("something_new"))
        // The sentence behind the mark is the one the row used to print.
        let fine = try decode(OwnerDevice.self, row(since: NSNull(), lastSeen: 1_940.0, contact: 1_940.0))
        #expect(fine.mark(now: 2_000).detail == fine.words(now: 2_000).words)
    }

    @Test func theLabelGivesTheNameThatTeamJsonHolds() throws {
        // The owner types what he calls it and its address; the name is the key of an entry, not a name he uses.
        #expect(OwnerDevices.name(from: "iPhone", taken: []) == "iphone")
        #expect(OwnerDevices.name(from: "  iPad mini (5th) ", taken: []) == "ipad-mini-5th")
        #expect(OwnerDevices.name(from: "2nd phone", taken: []) == "nd-phone")
        #expect(OwnerDevices.name(from: "12345", taken: []) == "device")
        #expect(OwnerDevices.name(from: "iPhone", taken: ["iphone"]) == "iphone-2")
        #expect(OwnerDevices.name(from: "iPhone", taken: ["iphone", "iphone-2"]) == "iphone-3")
        #expect(OwnerDevices.isName(OwnerDevices.name(from: String(repeating: "x", count: 60), taken: [])))
        let named = OwnerDeviceInput(label: " iPhone ", address: " 100.84.1.20 ").named(taken: ["iphone"])
        #expect(named.device == "iphone-2" && named.label == "iPhone" && named.address == "100.84.1.20")
        #expect(named.problem(existing: [], limit: 4) == nil)
        // A device that already has its name keeps it.
        #expect(OwnerDeviceInput(device: "ipad", label: "iPhone", address: "100.84.1.20").named(taken: []).device == "ipad")
    }

    @Test func theFormRefusesWhatTeamJsonCannotHold() throws {
        let existing = [try decode(OwnerDevice.self, row())]
        func problem(_ device: String, _ label: String, _ address: String, limit: Int = 4) -> String? {
            OwnerDeviceInput(device: device, label: label, address: address).problem(existing: existing, limit: limit)
        }
        #expect(problem("ipad", "iPad", "100.84.1.21") == nil)
        #expect(problem(" IPAD ", "iPad", "100.84.1.21") == nil)          // the name is trimmed and lower case
        #expect(problem("ipad", "iPad", "fd7a:115c:a1e0::1") == nil)         // an IPv6 address is an address
        #expect(problem("1pad", "iPad", "100.84.1.21")?.hasPrefix("Use a name") == true)
        #expect(problem("i", "iPad", "100.84.1.21")?.hasPrefix("Use a name") == true)
        #expect(problem("iphone", "iPad", "100.84.1.21")?.contains("is in Founderizer") == true)
        #expect(problem("ipad", "", "100.84.1.21")?.hasPrefix("Give a label") == true)
        #expect(problem("ipad", String(repeating: "x", count: 41), "100.84.1.21")?.hasPrefix("Give a label") == true)
        #expect(problem("ipad", "iPad", "ipad.local")?.contains("private network") == true)
        #expect(problem("ipad", "iPad", "100.84.1.20")?.contains("Another device") == true)
        #expect(problem("ipad", "iPad", "100.84.1.21", limit: 1)?.contains("Remove one") == true)
    }

    @Test func aSaveSendsTheTeamVersionAndARemovalSendsNoLabel() throws {
        let input = OwnerDeviceInput(device: "iphone", label: "  iPhone  ", address: " 100.84.1.20 ")
        let save = request(.ownerDevice(device: "iphone", sha256: hash, delete: false), text: try input.payload())
        #expect(save.route == "ui/owner/devices")
        #expect(save.command?.requiredFeature == "mobile")
        let body = try JSONSerialization.jsonObject(with: save.body()) as! [String: Any]
        #expect(body["base_sha256"] as? String == hash)
        #expect(body["device"] as? String == "iphone")
        #expect(body["label"] as? String == "iPhone")
        #expect(body["address"] as? String == "100.84.1.20")
        #expect(body["delete"] == nil)
        #expect(body["request_id"] as? String == save.requestID.uuidString.lowercased())
        #expect(body["db"] as? String == "db")
        let remove = request(.ownerDevice(device: "iphone", sha256: hash, delete: true))
        let removeBody = try JSONSerialization.jsonObject(with: remove.body()) as! [String: Any]
        #expect(removeBody["delete"] as? Bool == true)
        #expect(removeBody["label"] == nil && removeBody["address"] == nil)
        #expect(removeBody["base_sha256"] as? String == hash)
        // The saved request survives a relaunch as itself, so a retry is the same command, never a second device.
        let restored = try JSONDecoder().decode(PendingRequest.self, from: JSONEncoder().encode(save))
        #expect(restored == save)
        // A name or a version that the hub would refuse never leaves this Mac.
        #expect(throws: (any Error).self) { try request(.ownerDevice(device: "Phone", sha256: hash, delete: true)).body() }
        #expect(throws: (any Error).self) { try request(.ownerDevice(device: "iphone", sha256: "short", delete: true)).body() }
        #expect(throws: (any Error).self) {
            try request(.ownerDevice(device: "iphone", sha256: hash, delete: false),
                        text: try OwnerDeviceInput(device: "iphone", label: "iPhone", address: "iphone.local").payload()).body()
        }
        // A removal takes no text, so a body with one is not this command.
        #expect(throws: (any Error).self) {
            try request(.ownerDevice(device: "iphone", sha256: hash, delete: true), text: "note").body()
        }
    }

    @Test func theCodeCommandCarriesOnlyItsRequestAndItsGeneration() throws {
        let pending = request(.ownerDeviceCode(device: "iphone"))
        #expect(pending.route == "ui/owner/devices/iphone/code")
        #expect(pending.command?.requiredFeature == "mobile")
        let body = try JSONSerialization.jsonObject(with: pending.body()) as! [String: Any]
        #expect(Set(body.keys) == ["request_id", "db"])
        #expect(pending.command?.label == "New code for iphone")
        #expect(throws: (any Error).self) { try request(.ownerDeviceCode(device: "IPHONE")).body() }
    }

    @Test func theCodeForANewPhoneNamesNoDeviceAndCarriesNothingElse() throws {
        let pending = request(.newDeviceCode)
        #expect(pending.route == "ui/owner/devices/code")
        #expect(pending.command?.requiredFeature == "device_by_code")
        #expect(pending.command?.label == "New code for a new device")
        let body = try JSONSerialization.jsonObject(with: pending.body()) as! [String: Any]
        #expect(Set(body.keys) == ["request_id", "db"])
        var fields: [String: Any] = ["ok": true, "request_id": pending.requestID.uuidString, "client": "local",
                                     "replayed": false, "device": NSNull(), "code": "ABCD-2345", "expires": 2_600.0]
        #expect(try decode(ControlReceipt.self, fields).matches(pending))
        fields["device"] = "iphone"               // a device's own code does not answer this command
        #expect(try !decode(ControlReceipt.self, fields).matches(pending))
        fields["device"] = NSNull(); fields["code"] = NSNull(); fields["replayed"] = true
        #expect(try decode(ControlReceipt.self, fields).matches(pending))
        fields["replayed"] = false
        #expect(try !decode(ControlReceipt.self, fields).matches(pending))
    }

    @Test func aDeviceReceiptCannotAcknowledgeAnotherDeviceOrCommand() throws {
        let save = request(.ownerDevice(device: "iphone", sha256: hash, delete: false),
                           text: try OwnerDeviceInput(device: "iphone", label: "iPhone", address: "100.84.1.20").payload())
        var fields: [String: Any] = ["ok": true, "request_id": save.requestID.uuidString, "client": "local",
                                     "replayed": false, "device": "iphone", "deleted": false, "changed": true,
                                     "sha256": hash, "revision": revision]
        #expect(try decode(ControlReceipt.self, fields).matches(save))
        fields["changed"] = false                 // the same device again changes nothing, and is still its answer
        #expect(try decode(ControlReceipt.self, fields).matches(save))
        fields["device"] = "ipad"
        #expect(try !decode(ControlReceipt.self, fields).matches(save))
        fields["device"] = "iphone"; fields["deleted"] = true
        #expect(try !decode(ControlReceipt.self, fields).matches(save))
        let remove = request(.ownerDevice(device: "iphone", sha256: hash, delete: true))
        fields["request_id"] = remove.requestID.uuidString
        #expect(try decode(ControlReceipt.self, fields).matches(remove))
        fields["revision"] = "not-a-commit"
        #expect(try !decode(ControlReceipt.self, fields).matches(remove))
    }

    @Test func aRepeatOfTheCodeCommandIsAnswerEnoughAndCarriesNoCode() throws {
        let pending = request(.ownerDeviceCode(device: "iphone"))
        var fields: [String: Any] = ["ok": true, "request_id": pending.requestID.uuidString, "client": "local",
                                     "replayed": false, "device": "iphone", "label": "iPhone", "code": "ABCD-2345",
                                     "expires": 2_600.0]
        let first = try decode(ControlReceipt.self, fields)
        #expect(first.matches(pending))
        #expect(first.code == "ABCD-2345")
        // The hub keeps only the SHA-256 of a code, so a repeat of this request answers with none. That is the hub's
        // answer to this command, and the page offers a new code.
        fields["code"] = NSNull(); fields["replayed"] = true
        let again = try decode(ControlReceipt.self, fields)
        #expect(again.matches(pending))
        #expect(again.code == nil && again.expires == 2_600)
        // No code, and no repeat either: the hub did not answer this command.
        fields["replayed"] = false
        #expect(try !decode(ControlReceipt.self, fields).matches(pending))
        // A value that is not a code of this hub's alphabet is not a code.
        fields["code"] = "abcd-2345"
        #expect(try !decode(ControlReceipt.self, fields).matches(pending))
        fields["code"] = "ABCD2345"
        #expect(try !decode(ControlReceipt.self, fields).matches(pending))
        fields["code"] = "ABCI-O123"              // I, O, 0 and 1 are not in the hub's alphabet
        #expect(try !decode(ControlReceipt.self, fields).matches(pending))
        fields["code"] = "ABCD-2345"; fields["device"] = "ipad"
        #expect(try !decode(ControlReceipt.self, fields).matches(pending))
        fields["device"] = "iphone"; fields["expires"] = NSNull()
        #expect(try !decode(ControlReceipt.self, fields).matches(pending))
    }

    @Test func thePictureOfACodeCarriesTheHubAndTheCode() {
        let payload = OwnerDevices.enrollPayload(hub: hub, code: "ABCD-2345")
        let parts = URLComponents(string: payload)
        #expect(parts?.scheme == "fleet" && parts?.host == "enroll")
        #expect(parts?.queryItems?.first { $0.name == "code" }?.value == "ABCD-2345")
        #expect(parts?.queryItems?.first { $0.name == "hub" }?.value == hub.absoluteString)
        #expect(OwnerDevices.isCode("ABCD-2345") && !OwnerDevices.isCode("ABCD-23456"))
        #expect(parts?.queryItems?.contains { $0.name == "bind" } == false)
    }

    /// Owner feature `door_calls` (API 1.81): the picture also carries a one-time value, the phone binds its own key to
    /// it with HMAC-SHA256, and this Mac checks that binding byte for byte as Python's hmac writes it.
    @Test func thePicturesOneTimeValueBindsThePhonesKey() throws {
        let bind = "IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI"            // 32 bytes of 0x22, base64url
        let key = "BBERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERERE="
        #expect(DeviceBinding.binding(bind: bind, key: key) == "icF1fLEME6hdMpHIbhjrSMM8eXTk7kbknZJr3fyKnX4=")
        #expect(DeviceBinding.binding(bind: "short", key: key) == nil)
        #expect(DeviceBinding.binding(bind: bind, key: "AAAA") == nil)
        let fresh = DeviceBinding.newBind()
        #expect(fresh.count == 43 && fresh != DeviceBinding.newBind())
        let parts = URLComponents(string: OwnerDevices.enrollPayload(hub: hub, code: "ABCD-2345", bind: fresh))
        #expect(parts?.queryItems?.first { $0.name == "bind" }?.value == fresh)
        let defaults = try #require(UserDefaults(suiteName: "founderizer-test-\(UUID().uuidString)"))
        DeviceBinds.remember(bind, until: 2_000, in: defaults)
        DeviceBinds.remember(fresh, until: 1_000, in: defaults)
        #expect(DeviceBinds.all(now: 1_500, in: defaults) == [bind])
        DeviceBinds.forget(bind, in: defaults)
        #expect(DeviceBinds.all(now: 1_500, in: defaults).isEmpty)
        #expect(OwnerStatement.ownerDevice(fleet: "0f1e2d3c4b5a6978", device: "iphone", key: key, at: 1_761_300_008)
                == #"{"at":1761300008,"device":"iphone","fleet":"0f1e2d3c4b5a6978","key":"\#(key)","kind":"owner-device","v":1}"#)
        let row = #"{"device": "iphone", "label": "iPhone", "address": "100.64.0.9", "key": true, "signing_key": "\#(key)", "binding": "b", "certified": true}"#
        let decoded = try JSONDecoder().decode(OwnerDevice.self, from: Data(row.utf8))
        #expect(decoded.signing_key == key && decoded.binding == "b" && decoded.certified)
    }
}
