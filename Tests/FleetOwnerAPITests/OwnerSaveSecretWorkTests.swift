import Foundation
import Testing
@testable import FleetCore
@testable import FleetOwnerAPI

/// **The save of `save_secret`, as the work of the table** (the secrets plan, step E3): the entry in the hub's list
/// and the value in the vault, a save that goes on after a send that failed, the box that holds the value, a read of
/// the state, and what the table decides before and after a call's waits. With the stand-in desk of
/// `OwnerSaveSecretAppTests.swift`: no socket, no hub, and no wait for a fixed time.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct OwnerSaveSecretSaveTests {
    typealias Calls = SaveSecretCalls
    typealias Desk = StandInVaultDesk
    let value = exampleSecretValue
    let otherValue = "other-" + "value-4567"

    /// The texts of a command's body, for a look at what reaches the hub.
    func texts(_ body: [String: Any]) -> [String] { body.values.compactMap { $0 as? String } }

    /// A failure of a send with the hub's status and its own words, which no answer may pass on.
    nonisolated static func hub(_ status: Int) -> any Error {
        SaveBotToken.HubFailure.refused(status, "the words of the hub: EXAMPLE_API_KEY")
    }

    // ------------------------------------------------------------ the whole way

    /// **A new key goes the whole way**: the one line of the value part, without its line end, is the key of the
    /// item; the hub's step has the reference that the app made, the name, the kind, the variable and the
    /// fingerprint of the item; the item is sealed to the vault's key, and the sealed copy goes to the vault under
    /// the same reference; the app reads the fleet again; and the answer has the reference, the title and the kind.
    @Test func aNewKeyGoesTheWholeWay() async throws {
        let app = try Desk()
        let went = await Calls.saved(app, Calls.key(), value + "\n")
        let reference = went.reference
        #expect(went.answer == Calls.done(1, reference))
        #expect(app.references == [reference] && LoginSecret.isReference(reference))
        #expect(app.asked == ["secret", "item", "reference", "ready", "sealKey", "room", "seal", "register", "intake",
                              "refresh"])
        // The hub's step.
        let entry = try #require(app.registers.first)
        #expect(app.registers.count == 1 && entry.reference == reference && entry.title == "EXAMPLE_API_KEY")
        #expect(entry.kind == .apiKey && entry.variable == "EXAMPLE_API_KEY" && entry.address == nil)
        #expect(entry.item == ["username": "", "password": value])
        #expect(entry.body["login"] as? String == reference && entry.body["title"] as? String == "EXAMPLE_API_KEY")
        #expect(entry.body["kind"] as? String == "api_key" && entry.body["env"] as? String == "EXAMPLE_API_KEY")
        #expect(entry.body["address"] == nil)
        let prints = try #require(entry.body["fingerprints"] as? [[String: Any]])
        #expect(prints.count == 1 && prints.first?["kind"] as? String == "password")
        #expect(prints.first?["len"] as? Int == value.unicodeScalars.count)
        #expect(texts(entry.body).allSatisfy { !$0.contains(value) })
        // The vault's step.
        #expect(app.seals.count == 1 && app.seals.first?.item == entry.item && app.seals.first?.key == Desk.vaultKey)
        let stored = try #require(app.intakes.first)
        #expect(app.intakes.count == 1 && stored.reference == reference && AgeSeal.isSealed(stored.sealed))
        #expect(!stored.sealed.contains(value) && stored.sealed.count <= AgeSeal.maxCopy)
        // After it: one read of the fleet, no clipboard, and each send with the reading of the call.
        #expect(app.refreshes == 1 && app.clipboardReads == 0 && app.clears.isEmpty)
        #expect(app.places == [Desk.Place(), Desk.Place(), Desk.Place()])
        #expect(SaveSecret.said(app.table.state(of: Calls.id(1)), id: Calls.id(1)) == went.answer)
        #expect(app.logins?[reference] == TeamLogin(title: "EXAMPLE_API_KEY", protected: true, kind: "api_key",
                                                    env: "EXAMPLE_API_KEY"))
        #expect(app.looks.count == 1)
        #expect(await app.boxesGone())
    }

    /// **A new login goes the whole way**, from a pipe: its title is the host and the user name, its item has the
    /// user name, the value and the whole address, and the hub's step has no variable and no address.
    @Test func aNewLoginGoesTheWholeWay() async throws {
        let app = try Desk()
        let went = await Calls.saved(app, Calls.login(from: "stdin"), value + "\r\n")
        let title = "shop.example.com · owner@example.com"
        #expect(went.answer == Calls.done(1, went.reference, title: title, kind: "login"))
        let entry = try #require(app.registers.first)
        #expect(app.registers.count == 1 && entry.reference == went.reference && entry.title == title)
        #expect(entry.kind == .login && entry.variable == nil && entry.address == nil)
        #expect(entry.item == ["username": "owner@example.com", "password": value,
                               "url": "https://shop.example.com/login"])
        #expect(entry.body["kind"] as? String == "login" && entry.body["env"] == nil && entry.body["address"] == nil)
        // The path of the address is in the item alone: nothing of the command has it.
        #expect(texts(entry.body).allSatisfy { !$0.contains("/login") && !$0.contains(value) })
        #expect(app.intakes.count == 1 && app.intakes.first?.reference == went.reference)
        #expect(app.seals.first?.item == entry.item && app.refreshes == 1)
        #expect(app.logins?[went.reference] == TeamLogin(title: title, protected: true, kind: "login"))
        // A title that is longer than the list takes is cut as the form's own type cuts it.
        let long = String(repeating: "u", count: 100)
        let cut = await Calls.saved(app, Calls.login(2, username: long), value)
        var typed = Desk.secret(of: .init(kind: .login, url: "https://shop.example.com/login", username: long))
        typed.password = value
        #expect(typed.title.unicodeScalars.count == LoginSecret.maxLabel && typed.title.hasSuffix("…"))
        #expect(cut.answer == Calls.done(2, cut.reference, title: typed.title, kind: "login"))
        #expect(app.registers.last?.item["username"] == long)
    }

    /// **A key's address goes with the register, and a login's never** (the form's own rule,
    /// `SecretCommand.address(for:features:)`): only the scheme, the host and the port of an https address, only
    /// for an API key, and only to a hub that names `key_table`. The whole address stays in the item.
    @Test func aKeysAddressGoesWithTheRegisterAndALoginsNever() async throws {
        let app = try Desk()
        func entry(_ fields: [String: JSONValue]) async throws -> Desk.Register {
            let went = await Calls.saved(app, fields, value)
            #expect(Calls.words(went.answer) == nil, "\(fields)")
            let entry = try #require(app.registers.last)
            #expect(entry.reference == went.reference)
            return entry
        }
        let site = "https://api.example.com/v1/pathmark?querymark=1"
        let withPath = try await entry(Calls.key(1, env: "ONE_API_KEY", url: site))
        #expect(withPath.address == "https://api.example.com" && withPath.body["address"] as? String == "https://api.example.com")
        #expect(withPath.item["url"] == site)
        #expect(texts(withPath.body).allSatisfy { !$0.contains("pathmark") && !$0.contains("querymark") && !$0.contains("/v1") })
        let withPort = try await entry(Calls.key(2, env: "TWO_API_KEY", url: "https://example.com:8443/a/b"))
        #expect(withPort.address == "https://example.com:8443" && withPort.item["url"] == "https://example.com:8443/a/b")
        // An address that is not https, and a key with no address: the command has no such field.
        let plain = try await entry(Calls.key(3, env: "THREE_API_KEY", url: "http://api.example.com/v1"))
        #expect(plain.address == nil && plain.body["address"] == nil && plain.item["url"] == "http://api.example.com/v1")
        let bare = try await entry(Calls.key(4, env: "FOUR_API_KEY"))
        #expect(bare.address == nil && bare.body["address"] == nil && bare.item["url"] == nil)
        // A login, whatever its address is.
        for (number, url) in ["https://api.example.com/v1", "https://shop.example.com:8443/login", "http://shop.example.com"].enumerated() {
            let login = try await entry(Calls.login(5 + number, url: url, username: "owner-\(number)"))
            #expect(login.address == nil && login.body["address"] == nil && login.item["url"] == url, "\(url)")
        }
        // A hub from before the table: no address, also for a key with an https address.
        app.features = [CentralVault.feature, "secret_grants"]
        let older = try await entry(Calls.key(9, env: "NINE_API_KEY", url: site))
        #expect(older.address == nil && older.body["address"] == nil && older.item["url"] == site)
        #expect(app.registers.count == 8 && app.intakes.count == 8)
    }

    /// **The answer has its keys, and no fingerprint and no length**: a save that runs has `request_id`, `state`
    /// and `stage`; a save that is done has `request_id`, `state`, `reference`, `title` and `kind`, with
    /// `clipboard` after a save from the clipboard. Every field is a text, so no answer has a count, and none holds
    /// the value, a part of the sealed copy or a key. Two saves of one value have two references.
    @Test func theAnswerHasItsKeysAndNoFingerprintOrLength() async throws {
        let slow = try Desk(waitMax: Calls.near)
        slow.holdAt = ["register"]
        let running = await slow.answer(Calls.key(1), value)
        #expect(running == Calls.running(1, .registering))
        slow.holdAt = []
        slow.open("register")
        #expect(await slow.end(of: Calls.id(1)) == .ended(.done(.object([
            "request_id": .string(Calls.id(1)), "state": .string("done"),
            "reference": .string(slow.references.first ?? ""), "title": .string("EXAMPLE_API_KEY"),
            "kind": .string("api_key")]))))
        let app = try Desk()
        let file = await Calls.saved(app, Calls.key(1), value)
        let copied = await Calls.saved(app, Calls.login(2, from: "clipboard"))
        #expect(app.registers.count == 2 && app.registers.allSatisfy { $0.item["password"] == value })
        #expect(file.reference != copied.reference && file.reference != slow.references.first)
        let expected: [(OwnerChannel.Answer, [String])] = [
            (running, ["request_id", "stage", "state"]),
            (file.answer, ["kind", "reference", "request_id", "state", "title"]),
            (copied.answer, ["clipboard", "kind", "reference", "request_id", "state", "title"]),
        ]
        for (answer, keys) in expected {
            guard case .result(let json) = answer, let object = json.object else {
                Issue.record("no result: \(keys)")
                continue
            }
            #expect(object.keys.sorted() == keys)
            for (name, field) in object {
                let text = try #require(field.string, "\(name)")
                #expect(!text.contains(value) && text != String(value.count) && text != String(value.utf8.count), "\(name)")
            }
            let written = json.dumps()
            #expect(!written.contains(value) && !written.contains("age1") && !written.contains("AGE ENCRYPTED"))
            for name in ["fingerprint", "fingerprints", "hash", "len", "length", "count", "bytes", "value", "sealed",
                         "ciphertext", "env", "url", "username"] {
                #expect(object[name] == nil, "\(name)")
            }
        }
        #expect(copied.answer == Calls.done(2, copied.reference, title: "shop.example.com · owner@example.com",
                                            kind: "login", clipboard: "cleared"))
    }

    // ------------------------------------------------------------ a save that goes on

    /// **A save with nothing saved gets its own words, and the table keeps no record of it.** The hub refused the
    /// entry (a status under 500), the vault does not answer the hub (503), or the app could not seal the item: the
    /// first run says that nothing was saved, or sent, and the work leaves the table. The call has those words, and not "no save of this request_id":
    /// nothing stands between its `begin` and its wait, so the run cannot end before the call waits on it. A read
    /// of the state then finds no save, and the same call again is a new save, under a new reference.
    @Test func aSaveWithNothingSavedGetsItsWordsAndLeavesNoRecord() async throws {
        let cases: [(String, Int, String)] = [
            ("the hub refused the entry", 409, SaveSecret.hubRefused(status: 409)),
            ("a field's form at the hub", 400, SaveSecret.hubRefused(status: 400)),
            ("a registered value in the entry", 422, SaveSecret.hubRefused(status: 422)),
            ("the vault does not answer the hub", 503, SaveSecret.noVault),
        ]
        for (name, status, words) in cases {
            let app = try Desk()
            app.registerAnswers = [Self.hub(status), nil]
            #expect(await app.answer(Calls.key(), value) == .refused(words), "\(name)")
            #expect(app.table.state(of: Calls.id(1)) == nil, "\(name)")
            #expect(await app.answer(Calls.state()) == .refused(SaveSecret.noWork))
            #expect(app.registers.count == 1 && app.intakes.isEmpty && app.refreshes == 0 && app.clears.isEmpty)
            #expect(await app.boxesGone())
            let again = await Calls.saved(app, Calls.key(), value)
            #expect(again.answer == Calls.done(1, again.reference), "\(name)")
            #expect(app.references.count == 2 && app.references.first != again.reference)
            #expect(app.registers.count == 2 && app.registers.last?.reference == again.reference)
            #expect(app.intakes.count == 1 && app.intakes.first?.reference == again.reference)
        }
        // An item that the desk could not seal: nothing was sent at all, and the words are the seal's own. The
        // form took the fields, so "the form does not take these fields" would be untrue.
        let app = try Desk()
        app.sealFails = true
        #expect(await app.answer(Calls.key(), value) == .refused(SaveSecret.sealFailed))
        #expect(app.asked.suffix(3) == ["sealKey", "room", "seal"])
        #expect(app.table.state(of: Calls.id(1)) == nil && app.registers.isEmpty && app.intakes.isEmpty)
        #expect(await app.answer(Calls.state()) == .refused(SaveSecret.noWork))
        #expect(await app.boxesGone())
        // The same call again is a new save: it goes when the item can be sealed.
        app.sealFails = false
        let sealed = await Calls.saved(app, Calls.key(), value)
        #expect(sealed.answer == Calls.done(1, sealed.reference) && app.references.count == 2)
        #expect(SaveSecret.hubRefused(status: 409) == "The hub refused the new entry (status 409). Nothing was saved.")
        #expect(SaveSecret.noVault.hasSuffix("Nothing was saved."))
    }

    /// **A register with no answer goes on under the same reference.** Whether the hub has the entry is not known:
    /// the words say so and name the reference, the item stays in the box, and a read of the state says the same
    /// and starts nothing. The same call again joins the save: the vault's key is read again, the item is sealed
    /// again, and the entry goes under the SAME reference, with the value of the first call. A value part that
    /// came with the repeat is never used. After three runs with no answer the words are the final ones, and no
    /// fourth run starts.
    @Test func aRegisterWithNoAnswerGoesOnUnderTheSameReference() async throws {
        let app = try Desk()
        app.registerAnswers = [SaveBotToken.HubFailure.noAnswer, nil]
        let fields = Calls.key()
        let first = await app.answer(fields, value)
        let reference = try #require(app.references.first)
        #expect(first == .refused(SaveSecret.registerNotKnown(reference, id: Calls.id(1))))
        #expect(app.table.state(of: Calls.id(1)) == .ended(.failed(SaveSecret.registerNotKnown(reference, id: Calls.id(1)), again: true)))
        #expect(app.registers.count == 1 && app.intakes.isEmpty && app.refreshes == 0)
        #expect(app.looks.count == 1 && app.looks.first?.box?.holdsItem == true)
        #expect(app.looks.first?.box?.registered == false)
        // A read of the state: the same words, which name the whole call, and no run.
        #expect(await app.answer(Calls.state()) == first)
        await Calls.settle()
        #expect(app.registers.count == 1)
        // The words name the id itself: a caller that gave none cannot know it, and a refusal carries no id.
        #expect(Calls.words(first)?.contains("with the same fields, the same from and request_id " + Calls.id(1) + ":") == true)
        #expect(first == .refused("Whether the hub took the entry \(reference) is not known. Call save_secret again with "
                                 + "the same fields, the same from and request_id 00000000-0000-4000-8000-000000000001: it "
                                 + "goes on under the same reference."))
        // The same call again, with another value part.
        app.asked = []
        let second = await app.answer(fields, otherValue)
        #expect(second == Calls.done(1, reference))
        #expect(app.asked == ["sealKey", "seal", "register", "intake", "refresh"])
        #expect(app.references == [reference] && app.looks.count == 1)
        #expect(app.registers.count == 2 && app.registers.allSatisfy { $0.reference == reference })
        #expect(app.registers.allSatisfy { $0.item["password"] == value && $0.title == "EXAMPLE_API_KEY" })
        #expect(app.seals.count == 2 && app.seals.allSatisfy { $0.item["password"] == value && $0.key == Desk.vaultKey })
        #expect(app.intakes.count == 1 && app.intakes.first?.reference == reference && app.refreshes == 1)
        #expect(await app.boxesGone())
        // Once more: the save is done, and nothing is sent again.
        #expect(await app.answer(fields, value) == second)
        #expect(app.registers.count == 2 && app.intakes.count == 1)

        // Three runs with an outcome that is not known: no answer, a fault of the hub, an answer that nobody reads.
        let lost = try Desk()
        lost.registerAnswers = [SaveBotToken.HubFailure.noAnswer, Self.hub(500), SaveBotToken.HubFailure.unreadable]
        let one = await lost.answer(fields, value)
        let entry = try #require(lost.references.first)
        #expect(one == .refused(SaveSecret.registerNotKnown(entry, id: Calls.id(1))))
        #expect(await lost.answer(fields, value) == .refused(SaveSecret.registerNotKnown(entry, id: Calls.id(1))))
        #expect(lost.looks.first?.box?.holdsItem == true)
        let final = SaveSecret.registerNeverKnown(entry)
        #expect(await lost.answer(fields, value) == .refused(final))
        #expect(lost.table.state(of: Calls.id(1)) == .ended(.failed(final, again: false)))
        #expect(await lost.boxesGone())
        #expect(await lost.answer(fields, value) == .refused(final))
        #expect(await lost.answer(Calls.state()) == .refused(final))
        await Calls.settle()
        #expect(lost.registers.count == 3 && lost.registers.allSatisfy { $0.reference == entry } && lost.intakes.isEmpty)
        #expect(final == "The list may have the entry \(entry) with no value in the vault. Remove it with save_login "
                + "(login \(entry), delete true), then save again with a new request_id.")
    }

    /// **An intake that failed sends the same copy again.** The hub has the entry, so the item is wiped, and the
    /// sealed copy stays in the box. The same call again goes on at the vault's step: no read of the key, no seal
    /// and no entry a second time, and the copy is the one of the first run. After three runs the words are the
    /// final ones.
    @Test func anIntakeThatFailedSendsTheSameCopyAgain() async throws {
        let app = try Desk()
        app.intakeAnswers = [Self.hub(503), SaveBotToken.HubFailure.noAnswer, nil]
        let fields = Calls.login()
        let title = "shop.example.com · owner@example.com"
        let first = await app.answer(fields, value)
        let reference = try #require(app.references.first)
        #expect(first == .refused(SaveSecret.notInVault(reference, id: Calls.id(1))))
        #expect(first == .refused("The list has the entry \(reference), and its value is not in the vault yet. Call "
                                 + "save_secret again with the same fields, the same from and request_id "
                                 + "00000000-0000-4000-8000-000000000001."))
        #expect(app.table.state(of: Calls.id(1)) == .ended(.failed(SaveSecret.notInVault(reference, id: Calls.id(1)), again: true)))
        #expect(app.looks.first?.box?.holdsItem == false && app.looks.first?.box?.holdsSealed == true)
        #expect(app.looks.first?.box?.registered == true)
        #expect(app.registers.count == 1 && app.intakes.count == 1 && app.refreshes == 0)
        // The same call again: the later run is at the vault's step from its start.
        app.asked = []
        app.holdAt = ["intake"]
        let second = Calls.Call(app, fields, otherValue)
        await Calls.until { app.holds("intake") == 1 }
        #expect(await app.answer(Calls.state()) == Calls.running(1, .storing))
        app.holdAt = []
        app.open("intake")
        #expect(await second.ended() == .refused(SaveSecret.notInVault(reference, id: Calls.id(1))))
        #expect(app.asked == ["intake"])
        app.asked = []
        #expect(await app.answer(fields, value) == Calls.done(1, reference, title: title, kind: "login"))
        #expect(app.asked == ["intake", "refresh"])
        #expect(app.intakes.count == 3 && Set(app.intakes.map(\.sealed)).count == 1)
        #expect(app.intakes.allSatisfy { $0.reference == reference && AgeSeal.isSealed($0.sealed) })
        #expect(app.registers.count == 1 && app.seals.count == 1 && app.refreshes == 1 && app.references.count == 1)
        #expect(await app.boxesGone())

        let never = try Desk()
        never.intakeAnswers = [SaveBotToken.HubFailure.noAnswer]
        let one = await never.answer(fields, value)
        let entry = try #require(never.references.first)
        #expect(one == .refused(SaveSecret.notInVault(entry, id: Calls.id(1))))
        #expect(await never.answer(fields, value) == .refused(SaveSecret.notInVault(entry, id: Calls.id(1))))
        #expect(never.looks.first?.box?.holdsSealed == true)
        #expect(await never.answer(fields, value) == .refused(SaveSecret.neverInVault(entry)))
        #expect(never.table.state(of: Calls.id(1)) == .ended(.failed(SaveSecret.neverInVault(entry), again: false)))
        #expect(await never.boxesGone())
        #expect(await never.answer(fields, value) == .refused(SaveSecret.neverInVault(entry)))
        await Calls.settle()
        #expect(never.intakes.count == 3 && never.registers.count == 1 && never.refreshes == 0)
    }

    /// **A vault's refusal names the entry and its removal.** A status under 500 at the vault's step is a no for
    /// good: the list has an entry with no value. The words name the reference two times, say how to remove the
    /// entry, and ask for a new `request_id`; the hub's own words do not pass. The same call again starts nothing.
    /// The way out works as the words say: after the removal, the same name is saved under a new id.
    @Test func aVaultsRefusalNamesTheEntryAndItsRemoval() async throws {
        for status in [400, 404, 409, 422] {
            let app = try Desk()
            app.intakeAnswers = [SaveBotToken.HubFailure.refused(status, "the central vault refused: " + marker)]
            let first = await app.answer(Calls.key(), value)
            let reference = try #require(app.references.first)
            let words = SaveSecret.vaultRefused(reference)
            #expect(first == .refused(words), "\(status)")
            #expect(app.table.state(of: Calls.id(1)) == .ended(.failed(words, again: false)))
            #expect(await app.boxesGone())
            #expect(words == "The list has the entry \(reference) with no value in the vault. Remove it with save_login "
                    + "(login \(reference), delete true), then save again with a new request_id.")
            #expect(!words.contains(marker) && !words.contains("refused:"))
            #expect(await app.answer(Calls.key(), value) == first)
            #expect(await app.answer(Calls.state()) == first)
            await Calls.settle()
            #expect(app.registers.count == 1 && app.intakes.count == 1 && app.refreshes == 0 && app.clears.isEmpty)
            // A new id while the entry is in the list: the name is held. After the removal, it goes.
            #expect(await app.answer(Calls.key(2), value) == .refused(SaveSecret.held))
            app.logins?[reference] = nil
            app.intakeAnswers = [nil]
            let again = await Calls.saved(app, Calls.key(2), value)
            #expect(again.answer == Calls.done(2, again.reference) && again.reference != reference)
        }
    }

    // ------------------------------------------------------------ the box

    /// **The item is wiped once the entry exists.** While the hub's step is on its way, the box has the item and
    /// its sealed copy. When the hub confirmed the entry, the item is gone and the copy stays for the vault. When
    /// the vault took the copy, that is gone too, and with the work's end the box itself.
    @Test func theItemIsWipedOnceTheEntryExists() async throws {
        let app = try Desk()
        app.holdAt = ["register", "intake"]
        let call = Calls.Call(app, Calls.key(), value)
        await Calls.until { app.holds("register") == 1 }
        #expect(app.looks.count == 1 && app.looks.first?.box?.holdsItem == true)
        #expect(app.looks.first?.box?.holdsSealed == true && app.looks.first?.box?.registered == false)
        #expect(StandInVaultDesk.item(app.looks.first?.box?.itemCopy() ?? Data())["password"] == value)
        app.open("register")
        await Calls.until { app.holds("intake") == 1 }
        #expect(app.looks.first?.box?.holdsItem == false && app.looks.first?.box?.registered == true)
        #expect(app.looks.first?.box?.itemCopy().isEmpty == true)
        #expect(app.looks.first?.box?.holdsSealed == true)
        #expect(app.looks.first?.box?.sealedText == app.intakes.first?.sealed)
        #expect(!call.came)
        app.holdAt = []
        app.open("intake")
        #expect(await call.ended() == Calls.done(1, app.references.first ?? ""))
        #expect(await app.boxesGone())
    }

    /// **The box wipes what it holds**, each thing when the save needs it no more. The `Data` that brought the
    /// item is wiped as the box takes it. A seal keeps the copy, and a second one takes the place of the first.
    /// The entry in the list ends the item; the vault's yes ends the copy; and an end for good ends both.
    @Test func theBoxWipesWhatItHolds() throws {
        var typed = Desk.secret(of: .init(kind: .apiKey, env: "EXAMPLE_API_KEY"))
        typed.password = value
        var item = try typed.value()
        let bytes = [UInt8](item)
        #expect(bytes.count > value.utf8.count && bytes.contains { $0 != 0 })
        let reference = "bws://" + Calls.id(7)
        let box = SaveSecret.Kept(reference: reference, taking: &item)
        // The bytes that came are zeros now, in their place, and the box has its own.
        #expect(item.count == bytes.count && item.allSatisfy { $0 == 0 })
        #expect([UInt8](box.itemCopy()) == bytes && box.holdsItem && !box.holdsSealed && !box.registered)
        #expect(box.reference == reference && box.sealedText == nil)
        // A copy that the box gives out is a copy: a change of it does not reach the box.
        var copy = box.itemCopy()
        OwnerChannel.wipe(&copy)
        #expect([UInt8](box.itemCopy()) == bytes)
        // No copy from the desk is no seal.
        let none = box.seal(to: Desk.vaultKey, with: { _, _ in nil })
        let empty = box.seal(to: Desk.vaultKey, with: { _, _ in "" })
        #expect(!none && !empty && !box.holdsSealed)
        var sealedTo: [String] = []
        var sealedItems: [[UInt8]] = []
        let first = box.seal(to: Desk.vaultKey, with: { item, key in
            sealedItems.append([UInt8](item))
            sealedTo.append(key)
            return "the first copy"
        })
        #expect(first && box.sealedText == "the first copy" && box.holdsSealed)
        let second = box.seal(to: Desk.otherKey, with: { item, key in
            sealedItems.append([UInt8](item))
            sealedTo.append(key)
            return "the second copy"
        })
        #expect(second && box.sealedText == "the second copy" && sealedTo == [Desk.vaultKey, Desk.otherKey])
        #expect(sealedItems == [bytes, bytes])
        // With its item and its sealed copy in it, the box prints as hidden in every way that Swift prints a value.
        func printed<T>(_ value: T) -> [String] {
            var dumped = ""
            dump(value, to: &dumped)
            return [String(describing: value), String(reflecting: value), "\(value)", dumped]
        }
        for text in printed(box) {
            #expect(text.contains("(hidden)"), "\(text)")
            #expect(!text.contains(reference) && !text.contains("item") && !text.contains("sealed"), "\(text)")
            #expect(!text.contains("the second copy") && !text.contains("\(bytes[1]), \(bytes[2])"), "\(text)")
        }
        #expect(Mirror(reflecting: box).children.isEmpty)
        // A class with the same things and no rule of its own shows them, so each check above can fail.
        final class Plain {
            let reference: String
            let item: [UInt8]
            let sealed: String
            init(reference: String, item: [UInt8], sealed: String) {
                self.reference = reference
                self.item = item
                self.sealed = sealed
            }
        }
        let plain = printed(Plain(reference: reference, item: bytes, sealed: "the second copy")).last ?? ""
        #expect(plain.contains(reference) && plain.contains("item") && plain.contains("the second copy"))
        box.entered()
        #expect(!box.holdsItem && box.itemCopy().isEmpty && box.registered && box.sealedText == "the second copy")
        // With no item there is nothing to seal: the copy that the vault waits for stays.
        let third = box.seal(to: Desk.vaultKey, with: { _, _ in "a third copy" })
        #expect(!third && box.sealedText == "the second copy")
        box.stored()
        #expect(!box.holdsSealed && box.sealedText == nil)
        // An end for good, from each state.
        var again = try typed.value()
        let other = SaveSecret.Kept(reference: reference, taking: &again)
        let sealed = other.seal(to: Desk.vaultKey, with: { _, _ in "a copy" })
        #expect(sealed && other.holdsItem && other.holdsSealed)
        other.wipe()
        #expect(!other.holdsItem && !other.holdsSealed && other.itemCopy().isEmpty && other.sealedText == nil)
    }

    /// **The box goes with its work, and no call keeps it.** Only the work's closure has the box after `begin`:
    /// the box goes when the save is done, when nothing was saved, and at a failure for good. While the save can
    /// go on, the box stays, with what the next run needs. It goes with the record that leaves the table by a
    /// count, with no call and no run: after 16 later calls, and when four later saves ended. A call that is
    /// refused after its item was made keeps no box either.
    @Test func theBoxGoesWithItsWorkAndNoCallKeepsIt() async throws {
        // Done, nothing saved, and a no for good.
        let ends: [(String, (Desk) -> Void)] = [
            ("done", { _ in }),
            ("nothing saved", { $0.registerAnswers = [Self.hub(409)] }),
            ("the vault refused", { $0.intakeAnswers = [Self.hub(409)] }),
        ]
        for (name, change) in ends {
            let app = try Desk()
            change(app)
            _ = await app.answer(Calls.key(), value)
            #expect(app.looks.count == 1, "\(name)")
            #expect(await app.boxesGone(), "\(name)")
        }
        // A refusal after the item was made, at each check on the way to `begin`.
        let refusals: [(Desk) -> Void] = [{ $0.ready = false }, { $0.features = [] }, { $0.logins = nil },
                                          { $0.cancelAt = "room" }]
        for change in refusals {
            let app = try Desk()
            change(app)
            #expect(Calls.words(await Calls.call(app, Calls.key(), value)) != nil)
            #expect(app.looks.count == 1 && app.table.state(of: Calls.id(1)) == nil)
            #expect(await app.boxesGone())
        }
        // A save that can go on keeps its box, and the record's 16 later calls end both.
        let counted = try Desk()
        counted.registerAnswers = [SaveBotToken.HubFailure.noAnswer]
        let first = await counted.answer(Calls.key(), value)
        let reference = try #require(counted.references.first)
        #expect(first == .refused(SaveSecret.registerNotKnown(reference, id: Calls.id(1))))
        for _ in 1..<LinkWork.callsMax { #expect(await counted.table.wait(Calls.id(9)) == nil) }
        await Calls.settle()
        #expect(counted.looks.first?.box?.holdsItem == true)
        // Reads of the state are no calls: they change nothing here.
        for _ in 0..<40 { #expect(await counted.answer(Calls.state()) == first) }
        #expect(counted.looks.first?.box != nil)
        #expect(await counted.table.wait(Calls.id(9)) == nil)
        #expect(counted.table.state(of: Calls.id(1)) == nil)
        #expect(await counted.boxesGone())
        #expect(await counted.answer(Calls.state()) == .refused(SaveSecret.noWork))
        // The same, when four later saves ended: three leave the record there, and the fourth takes it away.
        let full = try Desk()
        full.registerAnswers = [SaveBotToken.HubFailure.noAnswer, nil]
        _ = await full.answer(Calls.key(), value)
        for number in 2...(LinkWork.keptMax + 1) {
            #expect(full.looks.first?.box?.holdsItem == true, "\(number)")
            #expect(full.table.state(of: Calls.id(1)) != nil, "\(number)")
            let later = await Calls.saved(full, Calls.key(number, env: "LATER_\(number)_API_KEY"), value)
            #expect(later.answer == Calls.done(number, later.reference, title: "LATER_\(number)_API_KEY"))
        }
        #expect(full.table.state(of: Calls.id(1)) == nil)
        #expect(await full.boxesGone())
    }

    // ------------------------------------------------------------ a read of the state, and a save that runs

    /// **A read of a save's state takes only the id and changes nothing.** No record: `noWork`. A save that runs:
    /// its stage, at once and with no wait. A save that is done: its answer. A read asks no desk, reads no
    /// clipboard, makes no box, and is no counted call: 48 reads leave the record where it was. A value part that
    /// came with a read is not looked at.
    @Test func aStateReadTakesOnlyTheIdAndChangesNothing() async throws {
        let app = try Desk()
        #expect(await app.answer(Calls.state()) == .refused(SaveSecret.noWork))
        #expect(await app.answer(Calls.state(), value) == .refused(SaveSecret.noWork))
        #expect(await app.answer(Calls.state(), bytes: [0xFF, 0xFE, 0xFD]) == .refused(SaveSecret.noWork))
        #expect(app.asked.isEmpty && app.table.state(of: Calls.id(1)) == nil)
        app.holdAt = ["register", "intake"]
        let call = Calls.Call(app, Calls.key(), value)
        await Calls.until { app.holds("register") == 1 }
        let asked = app.asked
        // The work stands at the hub's step, and the read comes back with no wait: the table's limit is far.
        #expect(await app.answer(Calls.state()) == Calls.running(1, .registering))
        #expect(await app.answer(Calls.state(), "short") == Calls.running(1, .registering))
        #expect(app.table.waiting == 1 && !call.came)
        app.open("register")
        await Calls.until { app.holds("intake") == 1 }
        #expect(await app.answer(Calls.state()) == Calls.running(1, .storing))
        #expect(await app.answer(Calls.state(2)) == .refused(SaveSecret.noWork))
        app.holdAt = []
        app.open("intake")
        let done = await call.ended()
        #expect(done == Calls.done(1, app.references.first ?? ""))
        for _ in 0..<(LinkWork.callsMax * 3) { #expect(await app.answer(Calls.state()) == done) }
        #expect(app.table.state(of: Calls.id(1)) != nil)
        // Nothing but the work's own steps asked the desk.
        #expect(app.asked == asked + ["intake", "refresh"])
        #expect(app.clipboardReads == 0 && app.looks.count == 1 && app.references.count == 1 && app.table.waiting == 0)
        // A null field was not given: this is a read of the state too.
        #expect(await app.answer(["request_id": .string(Calls.id(1)), "kind": .null, "from": .null]) == done)
    }

    /// **A save that takes longer than its call answers that it runs, and goes on.** The call's wait ends at its
    /// limit: the answer has the stage, and the work stands where it was. The same call again joins and waits
    /// again; nothing is sent twice. And the end of a call (its connection ended) ends its wait at once and never
    /// the work, which goes on to the vault.
    @Test func aSaveThatTakesLongerThanItsCallAnswersRunningAndGoesOn() async throws {
        let app = try Desk(waitMax: Calls.near)
        app.holdAt = ["register"]
        #expect(await app.answer(Calls.key(), value) == Calls.running(1, .registering))
        #expect(app.holds("register") == 1 && app.table.waiting == 0)
        #expect(await app.answer(Calls.key(), value) == Calls.running(1, .registering))
        #expect(app.registers.count == 1 && app.references.count == 1 && app.looks.count == 1)
        app.holdAt = ["intake"]
        app.open("register")
        await Calls.until { app.holds("intake") == 1 }
        #expect(await app.answer(Calls.key(), value) == Calls.running(1, .storing))
        app.holdAt = []
        app.open("intake")
        let reference = try #require(app.references.first)
        #expect(SaveSecret.said(await app.end(of: Calls.id(1)), id: Calls.id(1)) == Calls.done(1, reference))
        #expect(await app.answer(Calls.key(), value) == Calls.done(1, reference))
        #expect(app.registers.count == 1 && app.intakes.count == 1)

        // The end of the call: the wait ends by the cancel, far under the table's limit of this desk.
        let other = try Desk()
        other.holdAt = ["register"]
        let call = Calls.Call(other, Calls.key(), value)
        await Calls.until { other.table.waiting == 1 && other.holds("register") == 1 }
        #expect(other.table.waiting == 1)
        call.cancel()
        #expect(await call.ended() == Calls.running(1, .registering))
        #expect(other.table.waiting == 0 && other.holds("register") == 1)
        other.holdAt = []
        other.open("register")
        let entry = try #require(other.references.first)
        #expect(SaveSecret.said(await other.end(of: Calls.id(1)), id: Calls.id(1)) == Calls.done(1, entry))
        #expect(other.intakes.count == 1 && other.refreshes == 1)
        #expect(await other.boxesGone())
    }

    // ------------------------------------------------------------ one run, by its number

    @MainActor
    final class Stages { var all: [LinkWork.Stage] = [] }

    static let reference = "bws://" + SaveSecretCalls.id(77)
    static let fields = SaveSecret.Fields(kind: .apiKey, env: "EXAMPLE_API_KEY", url: "https://api.example.com/v1")

    /// One run of the work with the number `attempt`, on a new desk that `change` set up and with a new box: with
    /// the item for a run before the hub's entry, or with the sealed copy alone for a run after it.
    func run(_ attempt: Int, registered: Bool = false,
             _ change: (Desk) throws -> Void) async throws -> (ended: LinkWork.Ended, app: Desk, box: SaveSecret.Kept,
                                                               stages: [LinkWork.Stage]) {
        let app = try Desk()
        try change(app)
        var typed = Desk.secret(of: Self.fields)
        typed.password = value
        var item = try typed.value()
        let box = SaveSecret.Kept(reference: Self.reference, taking: &item)
        if registered {
            let sealed = box.seal(to: Desk.vaultKey, with: { item, key in try? AgeSeal.seal(item, to: key) })
            #expect(sealed)
            box.entered()
        }
        let draft = SaveSecret.Draft(title: "EXAMPLE_API_KEY", kind: .apiKey, variable: "EXAMPLE_API_KEY")
        let parts = SaveSecret.Parts(id: Calls.id(1), fields: Self.fields, draft: draft, place: Desk.Place(),
                                     key: Desk.vaultKey, clipboard: nil)
        let stages = Stages()
        let ended = await SaveSecret.run(box, parts, desk: app.desk, stage: { stages.all.append($0) }, attempt: attempt)
        return (ended, app, box, stages.all)
    }

    /// **A later run never says that nothing was saved, and the last run has the final words.**
    ///
    /// - The first run: a 503 is a vault that does not answer, and another status under 500 is the hub's refusal;
    ///   nothing was saved, and the box is wiped. No answer, an answer that could not be read, another error and a
    ///   status of 500 and above are "not known", and the item stays.
    /// - A later run, before the hub confirmed the entry: an earlier request may have arrived, so every failure is
    ///   "not known", also a 503, a refusal, a vault's key that cannot be read again and a seal that failed. No
    ///   run with a number above 1 gives `nothing`. (Another key than the pinned one ends the save with its own
    ///   words: `anotherKeyAtALaterRunEndsTheSaveWithItsOwnWords`.)
    /// - The run with the number `LinkWork.triesMax` gives the final words itself, with `again` false, and wipes
    ///   the box.
    /// - After the entry: a status under 500 is a no for good at each run, and every other failure can be tried
    ///   again, to the last run.
    @Test func aLaterRunNeverSaysThatNothingWasSavedAndTheLastRunHasTheFinalWords() async throws {
        let reference = Self.reference
        let under = [400, 404, 409, 422], over = [500, 502]
        let lost: [any Error] = [SaveBotToken.HubFailure.noAnswer, SaveBotToken.HubFailure.unreadable, URLError(.timedOut)]
        let done = LinkWork.Ended.done(.object(["request_id": .string(Calls.id(1)), "state": .string("done"),
                                                "reference": .string(reference), "title": .string("EXAMPLE_API_KEY"),
                                                "kind": .string("api_key")]))
        #expect(LinkWork.triesMax == 3)

        // The first run, at the hub's step.
        let good = try await run(1) { _ in }
        #expect(good.ended == done && good.stages == [.registering, .storing])
        #expect(good.app.asked == ["seal", "register", "intake", "refresh"])
        #expect(good.app.registers.first?.reference == reference && good.app.registers.first?.address == "https://api.example.com")
        #expect(!good.box.holdsItem && !good.box.holdsSealed)
        for status in under {
            let ran = try await run(1) { $0.registerAnswers = [Self.hub(status)] }
            #expect(ran.ended == .nothing(SaveSecret.hubRefused(status: status)), "\(status)")
            #expect(!ran.box.holdsItem && !ran.box.holdsSealed && ran.app.intakes.isEmpty && ran.stages == [.registering])
        }
        let noVault = try await run(1) { $0.registerAnswers = [Self.hub(503)] }
        #expect(noVault.ended == .nothing(SaveSecret.noVault) && !noVault.box.holdsItem && !noVault.box.holdsSealed)
        for failure in over.map(Self.hub) + lost {
            let ran = try await run(1) { $0.registerAnswers = [failure] }
            #expect(ran.ended == .failed(SaveSecret.registerNotKnown(reference, id: Calls.id(1)), again: true), "\(failure)")
            #expect(ran.box.holdsItem && !ran.box.registered && ran.app.intakes.isEmpty)
        }
        let noSeal = try await run(1) { $0.sealFails = true }
        #expect(noSeal.ended == .nothing(SaveSecret.sealFailed) && noSeal.app.asked == ["seal"] && !noSeal.box.holdsItem)
        // The first run seals to the key that its call read, and does not read the vault again.
        let unread = try await run(1) { $0.readingFails = true }
        #expect(unread.ended == done && !unread.app.asked.contains("sealKey"))

        // A later run, at the hub's step.
        var faults: [(String, Bool, (Desk) throws -> Void)] = [
            ("no vault", true, { $0.features = [] }), ("no pin", true, { $0.pins = [:] }),
            ("no recovery key", true, { $0.reading = try Desk.reading(recovery: nil) }),
            ("a read of the key that failed", true, { $0.readingFails = true }),
            ("a seal that failed", false, { $0.sealFails = true }),
        ]
        for status in [503] + under + over {
            faults.append(("status \(status)", false, { $0.registerAnswers = [Self.hub(status)] }))
        }
        for failure in lost { faults.append(("\(failure)", false, { $0.registerAnswers = [failure] })) }
        var later = 0
        for attempt in 2...LinkWork.triesMax {
            let last = attempt == LinkWork.triesMax
            let words = last ? SaveSecret.registerNeverKnown(reference)
                : SaveSecret.registerNotKnown(reference, id: Calls.id(1))
            for (name, atTheKey, fault) in faults {
                let ran = try await run(attempt, fault)
                later += 1
                if case .nothing = ran.ended { Issue.record("nothing was saved, said run \(attempt): \(name)") }
                #expect(ran.ended == .failed(words, again: !last), "\(name), run \(attempt)")
                #expect(ran.box.holdsItem == !last && !ran.box.registered && ran.app.intakes.isEmpty, "\(name), run \(attempt)")
                #expect(ran.stages == [.registering], "\(name)")
                // A vault whose key cannot be read again gets no copy and no entry.
                if atTheKey { #expect(ran.app.asked == ["sealKey"] && ran.app.seals.isEmpty && ran.app.registers.isEmpty, "\(name)") }
            }
            let again = try await run(attempt) { _ in }
            #expect(again.ended == done && again.stages == [.registering, .storing])
            #expect(again.app.asked == ["sealKey", "seal", "register", "intake", "refresh"])
        }
        #expect(later == 2 * faults.count && faults.count == 15)

        // After the entry, at the vault's step: the kept copy, and no read, no seal and no entry again.
        for attempt in 1...LinkWork.triesMax {
            let last = attempt == LinkWork.triesMax
            let stored = try await run(attempt, registered: true) { _ in }
            #expect(stored.ended == done && stored.stages == [.storing] && stored.app.asked == ["intake", "refresh"])
            #expect(AgeSeal.isSealed(stored.app.intakes.first?.sealed ?? ""))
            for status in under {
                let ran = try await run(attempt, registered: true) { $0.intakeAnswers = [Self.hub(status)] }
                #expect(ran.ended == .failed(SaveSecret.vaultRefused(reference), again: false), "\(status), run \(attempt)")
                #expect(!ran.box.holdsSealed && ran.app.asked == ["intake"] && ran.stages == [.storing])
            }
            for failure in ([503] + over).map(Self.hub) + lost {
                let ran = try await run(attempt, registered: true) { $0.intakeAnswers = [failure] }
                let words = last ? SaveSecret.neverInVault(reference)
                    : SaveSecret.notInVault(reference, id: Calls.id(1))
                #expect(ran.ended == .failed(words, again: !last), "\(failure), run \(attempt)")
                #expect(ran.box.holdsSealed == !last && ran.app.asked == ["intake"] && ran.app.refreshes == 0)
            }
        }

        // The same through the table and three calls: no answer, then a 503, then the hub's refusal.
        let app = try Desk()
        app.registerAnswers = [SaveBotToken.HubFailure.noAnswer, Self.hub(503), Self.hub(409)]
        let first = await app.answer(Calls.key(), value)
        let entry = try #require(app.references.first)
        #expect(first == .refused(SaveSecret.registerNotKnown(entry, id: Calls.id(1))))
        #expect(await app.answer(Calls.key(), value) == .refused(SaveSecret.registerNotKnown(entry, id: Calls.id(1))))
        #expect(app.table.state(of: Calls.id(1)) == .ended(.failed(SaveSecret.registerNotKnown(entry, id: Calls.id(1)), again: true)))
        #expect(await app.answer(Calls.key(), value) == .refused(SaveSecret.registerNeverKnown(entry)))
        #expect(app.table.state(of: Calls.id(1)) == .ended(.failed(SaveSecret.registerNeverKnown(entry), again: false)))
        #expect(await app.answer(Calls.key(), value) == .refused(SaveSecret.registerNeverKnown(entry)))
        await Calls.settle()
        #expect(app.registers.count == 3 && app.registers.allSatisfy { $0.reference == entry })
        #expect(app.asked.filter { $0 == "sealKey" }.count == 3 && app.intakes.isEmpty)
        for words in [SaveSecret.noVault, SaveSecret.hubRefused(status: 409)] {
            #expect(await app.answer(Calls.state()) != .refused(words))
        }
    }

    /// **Another key at a later run ends the save, with its own words.** A later run reads the vault's key again.
    /// When that key is not the one that this Mac pinned, nothing is sealed to it and nothing is sent: no seal and
    /// no entry. The save ends for good at that run, the second one as the last one, and the box is wiped at once.
    /// The words say that the save has ended, tell the owner's rule about the vault's Set up, and name the entry
    /// that may be in the list. The table keeps that failure: the next call of the same id reads the same words
    /// and starts nothing, also when the pinned key is back. A run after the hub's entry reads no key.
    @Test func anotherKeyAtALaterRunEndsTheSaveWithItsOwnWords() async throws {
        let reference = Self.reference
        let words = SaveSecret.otherKeyLater(reference)
        #expect(words == "The central vault answers now with another key than the one that this Mac pinned, so the "
                + "value was not sent, and this save has ended. Tell the owner, and save nothing until the owner "
                + "knows why: do not set the vault up again to get past this. If the list has the entry \(reference), "
                + "it has no value in the vault: remove it with save_login (login \(reference), delete true).")
        let changes: [(String, (Desk) throws -> Void)] = [
            ("this Mac's pin is another key", { $0.pins = [Desk.fleet: Desk.otherKey] }),
            ("the vault answers with another key", { $0.reading = try Desk.reading(recipient: Desk.otherKey) }),
            ("the vault gives no key that can be read", { $0.reading = try Desk.reading(recipient: nil) }),
        ]
        for attempt in 2...LinkWork.triesMax {
            for (name, change) in changes {
                let ran = try await run(attempt, change)
                #expect(ran.ended == .failed(words, again: false), "\(name), run \(attempt)")
                #expect(ran.app.asked == ["sealKey"], "\(name), run \(attempt)")
                #expect(ran.app.seals.isEmpty && ran.app.registers.isEmpty && ran.app.intakes.isEmpty && ran.app.refreshes == 0)
                #expect(!ran.box.holdsItem && !ran.box.holdsSealed && !ran.box.registered && ran.stages == [.registering])
            }
        }
        // The first run seals to the key that its call read, and a run after the entry sends the kept copy:
        // neither reads the key again.
        for (attempt, registered) in [(1, false), (2, true), (3, true)] {
            let ran = try await run(attempt, registered: registered) { $0.pins = [Desk.fleet: Desk.otherKey] }
            guard case .done = ran.ended else {
                Issue.record("run \(attempt) did not end done")
                continue
            }
            #expect(!ran.app.asked.contains("sealKey"))
        }

        // Through the table: the key changes before the second run, or before the last one.
        for runs in 2...LinkWork.triesMax {
            let app = try Desk()
            app.registerAnswers = [SaveBotToken.HubFailure.noAnswer]
            for _ in 1..<runs {
                let answer = await app.answer(Calls.key(), value)
                #expect(answer == .refused(SaveSecret.registerNotKnown(app.references.first ?? "", id: Calls.id(1))))
            }
            let entry = try #require(app.references.first)
            #expect(app.looks.first?.box?.holdsItem == true && app.registers.count == runs - 1)
            app.pins = [Desk.fleet: Desk.otherKey]
            app.asked = []
            let ended = await app.answer(Calls.key(), value)
            #expect(ended == .refused(SaveSecret.otherKeyLater(entry)), "run \(runs)")
            #expect(app.table.state(of: Calls.id(1)) == .ended(.failed(SaveSecret.otherKeyLater(entry), again: false)))
            #expect(app.asked == ["sealKey"] && app.registers.count == runs - 1 && app.seals.count == runs - 1)
            #expect(await app.boxesGone())
            // The next call of the same id, and a read of its state: the same words, and nothing starts. Also with
            // the pinned key back: the save has ended.
            app.pins = [Desk.fleet: Desk.vaultKey]
            #expect(await app.answer(Calls.key(), value) == ended)
            #expect(await app.answer(Calls.state()) == ended)
            await Calls.settle()
            #expect(app.asked == ["sealKey"] && app.registers.count == runs - 1 && app.intakes.isEmpty)
            // A new save, under a new id, is the call's own check: with the key still another one, `otherKey`.
            app.pins = [Desk.fleet: Desk.otherKey]
            #expect(await app.answer(Calls.key(2, env: "OTHER_API_KEY"), value) == .refused(SaveSecret.otherKey))
        }
    }

    /// **A reading of the app that moved while the key was read is "not ready" in a call and "not known" in a later
    /// run.** The app shows another hub or another database than the one that the save reads with. That says
    /// nothing about the vault of the save's hub, so no answer says that the vault does not answer.
    /// - In a call's own check: `notReady`. Nothing is asked after the key (no room, no clipboard), and nothing is
    ///   sent.
    /// - At a second run: "not known", with the save's id, and the same call again goes on. Nothing is sealed and
    ///   nothing is sent at that run, and the item stays.
    /// - At the last run: the final words, and the box is wiped.
    @Test func aReadingThatMovedIsNotReadyInACallAndNotKnownAtALaterRun() async throws {
        // In a call, from a file and from the clipboard.
        let app = try Desk()
        app.movedFromAsk = 1
        #expect(await app.answer(Calls.key(1), value) == .refused(SaveSecret.notReady))
        #expect(app.asked == ["secret", "item", "reference", "ready", "sealKey"])
        app.asked = []
        #expect(await app.answer(Calls.key(2, from: "clipboard")) == .refused(SaveSecret.notReady))
        #expect(app.asked == ["secret", "ready", "sealKey"])
        #expect(app.clipboardReads == 0 && app.seals.isEmpty && app.registers.isEmpty && app.intakes.isEmpty)
        #expect(app.table.state(of: Calls.id(1)) == nil && app.table.state(of: Calls.id(2)) == nil)
        #expect(await app.boxesGone())
        // Another hub in the app is the same fact as another database.
        let elsewhere = try Desk()
        elsewhere.shows.hub = "https://other.example.com"
        #expect(await elsewhere.answer(Calls.key(1), value) == .refused(SaveSecret.notReady))
        #expect(elsewhere.asked == ["secret", "item", "reference", "ready", "sealKey"] && elsewhere.registers.isEmpty)
        // Not the words of a vault that does not answer: a hub that the app shows and that does not serve the
        // feature still gets those.
        #expect(SaveSecret.notReady != SaveSecret.noVault)
        let unserved = try Desk()
        unserved.features = ["secret_grants"]
        #expect(await unserved.answer(Calls.key(1), value) == .refused(SaveSecret.noVault))
        // With the reading back at the save's hub and database, the same call goes.
        app.shows = Desk.Place()
        app.movedFromAsk = nil
        let went = await Calls.saved(app, Calls.key(1), value)
        #expect(went.answer == Calls.done(1, went.reference))

        // A later run, on its own: the second one and the last one. No seal and no entry, at the key's read alone.
        let reference = Self.reference
        for attempt in 2...LinkWork.triesMax {
            let last = attempt == LinkWork.triesMax
            let words = last ? SaveSecret.registerNeverKnown(reference)
                : SaveSecret.registerNotKnown(reference, id: Calls.id(1))
            let changes: [(String, (Desk) throws -> Void)] = [
                ("another database", { $0.movedFromAsk = 1 }),
                ("another hub", { $0.shows.hub = "https://other.example.com" }),
            ]
            for (name, change) in changes {
                let ran = try await run(attempt, change)
                if case .nothing = ran.ended { Issue.record("nothing was saved, said run \(attempt): \(name)") }
                #expect(ran.ended == .failed(words, again: !last), "\(name), run \(attempt)")
                #expect(ran.app.asked == ["sealKey"], "\(name), run \(attempt)")
                #expect(ran.app.seals.isEmpty && ran.app.registers.isEmpty && ran.app.intakes.isEmpty && ran.app.refreshes == 0)
                #expect(ran.box.holdsItem == !last && !ran.box.registered && ran.stages == [.registering])
            }
        }

        // Through the table and three calls: no answer at the first run, and then the reading moved.
        let later = try Desk()
        later.registerAnswers = [SaveBotToken.HubFailure.noAnswer]
        let first = await later.answer(Calls.key(), value)
        let entry = try #require(later.references.first)
        let notKnown = SaveSecret.registerNotKnown(entry, id: Calls.id(1))
        #expect(first == .refused(notKnown) && later.registers.count == 1 && later.seals.count == 1)
        later.movedFromAsk = 2
        later.asked = []
        let second = await later.answer(Calls.key(), value)
        #expect(second == .refused(notKnown))
        #expect(Calls.words(second)?.contains("the same from and request_id " + Calls.id(1) + ":") == true)
        #expect(later.table.state(of: Calls.id(1)) == .ended(.failed(notKnown, again: true)))
        #expect(later.asked == ["sealKey"] && later.registers.count == 1 && later.seals.count == 1 && later.intakes.isEmpty)
        #expect(later.looks.first?.box?.holdsItem == true)
        let final = SaveSecret.registerNeverKnown(entry)
        let third = await later.answer(Calls.key(), value)
        #expect(third == .refused(final))
        #expect(later.table.state(of: Calls.id(1)) == .ended(.failed(final, again: false)))
        #expect(later.asked == ["sealKey", "sealKey"] && later.registers.count == 1 && later.seals.count == 1)
        #expect(later.intakes.isEmpty && later.refreshes == 0)
        #expect(await later.boxesGone())
        for answer in [second, third] {
            #expect(answer != .refused(SaveSecret.noVault) && answer != .refused(SaveSecret.notReady))
        }
        // The save has ended: the same call again and a read of its state say the final words, and nothing runs.
        #expect(await later.answer(Calls.key(), value) == third)
        #expect(await later.answer(Calls.state()) == third)
        await Calls.settle()
        #expect(later.asked == ["sealKey", "sealKey"] && later.registers.count == 1)
    }

    // ------------------------------------------------------------ the table, before and after the waits

    /// **Another save that runs, other fields under an id, and the caller's repeat are known before the value is
    /// looked at and before the clipboard is read.** While a save runs: another id is told that it runs, whatever
    /// its value part is and also from the clipboard; other fields under the id of the save are refused; and the
    /// same call again joins the save and waits on it, also with a value part that its `from` takes none of. None
    /// of these asks the desk, reads the clipboard or makes a box.
    @Test func busyOtherFieldsAndAJoinAreKnownBeforeTheValueIsLookedAt() async throws {
        let app = try Desk()
        app.holdAt = ["register"]
        let fields = Calls.key(1, from: "clipboard")
        let first = Calls.Call(app, fields)
        await Calls.until { app.holds("register") == 1 }
        let asked = app.asked
        #expect(app.clipboardReads == 1 && app.looks.count == 1)
        let others: [([String: JSONValue], String?)] = [
            (Calls.key(2, env: "OTHER_API_KEY"), value), (Calls.key(2, env: "OTHER_API_KEY"), "short"),
            (Calls.key(2, env: "OTHER_API_KEY"), nil), (Calls.login(2, from: "clipboard"), nil),
            (Calls.login(2, from: "clipboard"), value), (Calls.login(2, from: "stdin"), value),
        ]
        for (other, part) in others {
            #expect(await app.answer(other, part) == .refused(SaveSecret.busy), "\(other)")
        }
        let changed: [([String: JSONValue], String?)] = [
            (Calls.key(1, from: "file"), value), (Calls.key(1, from: "file"), "short"), (Calls.key(1, from: "file"), nil),
            (Calls.key(1, from: "clipboard", url: "https://api.example.com"), nil),
            (Calls.key(1, from: "clipboard", env: "OTHER_API_KEY"), value), (Calls.login(1, from: "clipboard"), nil),
        ]
        for (other, part) in changed {
            #expect(await app.answer(other, part) == .refused(SaveSecret.otherFields), "\(other)")
        }
        #expect(app.asked == asked && app.clipboardReads == 1 && app.looks.count == 1 && app.references.count == 1)
        #expect(app.table.state(of: Calls.id(2)) == nil && app.table.state(of: Calls.id(1)) == .running(.registering))
        // The repeat, with a value part that a call from the clipboard takes none of: it joins and waits.
        let joined = Calls.Call(app, fields, "short")
        await Calls.until { app.table.waiting == 2 }
        #expect(app.table.waiting == 2 && !joined.came && !first.came)
        #expect(app.asked == asked && app.clipboardReads == 1 && app.looks.count == 1)
        app.holdAt = []
        app.open("register")
        let done = await first.ended()
        #expect(done == Calls.done(1, app.references.first ?? "", clipboard: "cleared"))
        #expect(await joined.ended() == done)
        #expect(app.registers.count == 1 && app.intakes.count == 1 && app.clipboardReads == 1)
        // After the end: other fields are refused as before, the repeat has the answer, and another id starts.
        #expect(await app.answer(Calls.key(1, from: "file"), value) == .refused(SaveSecret.otherFields))
        #expect(await app.answer(fields, "short") == done)
        let next = await Calls.saved(app, Calls.key(2, env: "OTHER_API_KEY"), value)
        #expect(next.answer == Calls.done(2, next.reference, title: "OTHER_API_KEY"))
    }

    /// **`begin` is the decision, whatever the table said before the waits.** Two calls pass their looks at the
    /// table while neither has begun.
    /// - Two saves, the second one from the clipboard: it passed its second look at the table too, and it stands
    ///   in its read of the clipboard when the other save begins. After the read, `begin` tells it that another
    ///   save runs. Its box goes at once, nothing of it is sent, the clipboard is not cleared, and its id has no
    ///   record.
    /// - The same call two times: the one that begins second joins the save of the first. Its own box goes at
    ///   once, while that call still waits, so no frame of a call keeps a box; one entry is made, with the value
    ///   of the call that began.
    /// - One id with other fields: the one that begins second is refused, and its box goes.
    @Test func beginIsTheDecisionAfterTheWaits() async throws {
        // Two saves. The slow one stands in its read of the clipboard, as while macOS's question is up.
        let app = try Desk()
        app.holdAt = ["clipboard", "register"]
        let slow = Calls.Call(app, Calls.key(2, from: "clipboard", env: "OTHER_API_KEY"))
        await Calls.until { app.holds("clipboard") == 1 }
        #expect(app.clipboardReads == 1 && app.looks.isEmpty)
        let fast = Calls.Call(app, Calls.key(1), value)
        await Calls.until { app.holds("register") == 1 }
        #expect(app.looks.count == 1 && app.looks.first?.box?.holdsItem == true)
        #expect(app.table.state(of: Calls.id(1)) == .running(.registering))
        // The read comes back: the slow call makes its box, and then `begin` says busy.
        app.open("clipboard")
        #expect(await slow.ended() == .refused(SaveSecret.busy))
        #expect(app.clipboardReads == 1 && app.looks.count == 2 && app.looks.last?.box == nil)
        #expect(app.looks.first?.box != nil && app.table.state(of: Calls.id(2)) == nil)
        #expect(app.registers.count == 1 && app.registers.first?.title == "EXAMPLE_API_KEY" && app.clears.isEmpty)
        app.holdAt = []
        app.open("register")
        #expect(await fast.ended() == Calls.done(1, app.references.first ?? ""))
        #expect(app.clears.isEmpty && app.registers.count == 1)
        #expect(await app.boxesGone())

        // The same call two times, each with its own value part.
        let twice = try Desk()
        twice.holdAt = ["room", "register"]
        let second = Calls.Call(twice, Calls.key(1), otherValue)
        await Calls.until { twice.holds("room") == 1 }
        let begins = Calls.Call(twice, Calls.key(1), value)
        await Calls.until { twice.holds("room") == 2 }
        #expect(twice.looks.count == 2 && twice.looks.allSatisfy { $0.box?.holdsItem == true })
        twice.open("room", 1)
        await Calls.until { twice.holds("register") == 1 }
        twice.open("room", 0)
        await Calls.until { twice.table.waiting == 2 }
        // Both calls wait on the one save, and the box of the call that joined is gone already.
        #expect(twice.table.waiting == 2 && !second.came && !begins.came)
        #expect(twice.looks.first?.box == nil && twice.looks.last?.box != nil)
        twice.holdAt = []
        twice.open("register")
        let done = await begins.ended()
        #expect(done == Calls.done(1, twice.references.last ?? ""))
        #expect(await second.ended() == done)
        #expect(twice.registers.count == 1 && twice.registers.first?.item["password"] == value)
        #expect(twice.registers.first?.reference == twice.references.last && twice.intakes.count == 1)
        #expect(await twice.boxesGone())

        // One id, other fields.
        let mixed = try Desk()
        mixed.holdAt = ["room", "register"]
        let other = Calls.Call(mixed, Calls.key(1, from: "stdin"), otherValue)
        await Calls.until { mixed.holds("room") == 1 }
        let own = Calls.Call(mixed, Calls.key(1), value)
        await Calls.until { mixed.holds("room") == 2 }
        mixed.open("room", 1)
        await Calls.until { mixed.holds("register") == 1 }
        mixed.open("room", 0)
        #expect(await other.ended() == .refused(SaveSecret.otherFields))
        #expect(mixed.looks.first?.box == nil && mixed.looks.last?.box != nil)
        mixed.holdAt = []
        mixed.open("register")
        #expect(await own.ended() == Calls.done(1, mixed.references.last ?? ""))
        #expect(mixed.registers.count == 1 && mixed.registers.first?.item["password"] == value)
    }

    /// **The digest of a save is of the fields that the program sends**: for each source and each kind, the app's
    /// digest of a call is the table's digest of the plan's fields, so the caller's repeat through the program
    /// joins its save. The id is no part of it, a field with null is none, and another source is another save.
    @Test func theDigestIsOfTheFieldsThatTheProgramSends() throws {
        var digests: Set<[UInt8]> = []
        var count = 0
        for source in ["file", "stdin", "clipboard"] {
            for base in [SaveSecretSample.key, SaveSecretSample.login,
                         SaveSecretSample.with(SaveSecretSample.key, ["url": .string("https://api.example.com/v1")])] {
                var fields = SaveSecretSample.with(base, ["from": .string(source)])
                if source == "file" { fields["path"] = .string("/tmp/example") }
                let plan = try SaveSecret.plan(fields, standardInputFree: true).get()
                guard case .success(.save(_, let secret, let from, _)) = SaveSecret.read(plan.send, app: true) else {
                    Issue.record("the app did not take the plan: \(source)")
                    continue
                }
                let digest = SaveSecret.digest(of: secret, from: from)
                #expect(digest == LinkWork.digest(tool: SaveSecret.name, fields: plan.send), "\(source)")
                // Another id, and fields with null beside the others: the same save.
                var again = plan.send
                again["request_id"] = .string(SaveSecretCalls.id(5))
                again["path"] = .null
                if again["url"] == nil { again["url"] = .null }
                guard case .success(.save(_, let same, let sameFrom, _)) = SaveSecret.read(again, app: true) else {
                    Issue.record("the app did not take the fields with null: \(source)")
                    continue
                }
                #expect(SaveSecret.digest(of: same, from: sameFrom) == digest)
                digests.insert(digest)
                count += 1
            }
        }
        #expect(count == 9 && digests.count == 9)
    }
}

/// **`from` clipboard of `save_secret` in the app**, with the stand-in desk's clipboard: no test reads or writes the
/// real one.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct OwnerSaveSecretClipboardTests {
    typealias Calls = SaveSecretCalls
    typealias Desk = StandInVaultDesk
    let value = exampleSecretValue
    let fields = SaveSecretCalls.key(from: "clipboard")

    /// **The clipboard is read last and once**: after the fields, the form's own type, the reading, the vault's
    /// key and the room in the list, and before the item is made. Its text, as it is, is the value: nothing is
    /// taken off it. A call that an earlier check refuses reads nothing. A clipboard with no text, a text that is no
    /// value and a text that is too long get one sentence; a setting of macOS that denies the read and a read
    /// that is in flight get their own. Nothing is sent and nothing is cleared after any of them.
    @Test func theClipboardIsReadLastAndOnce() async throws {
        let app = try Desk()
        app.clipboard = .text(value, count: 41)
        let went = await Calls.saved(app, Calls.login(from: "clipboard"))
        #expect(went.answer == Calls.done(1, went.reference, title: "shop.example.com · owner@example.com",
                                          kind: "login", clipboard: "cleared"))
        #expect(app.clipboardReads == 1)
        #expect(app.asked == ["secret", "ready", "sealKey", "room", "clipboard", "item", "reference", "seal",
                              "register", "intake", "refresh", "clear"])
        #expect(app.registers.first?.item["password"] == value)
        #expect(app.clears.map(\.0) == [41] && app.clears.map(\.1) == [true])
        // Each earlier check: no read.
        let earlier: [(Desk) throws -> Void] = [
            { $0.ready = false }, { $0.features = [] }, { $0.pins = [:] }, { $0.pins = [Desk.fleet: Desk.otherKey] },
            { $0.reading = try Desk.reading(recovery: nil) }, { $0.readingFails = true }, { $0.logins = nil },
            { $0.listFails = true },
            { $0.logins = ["bws://" + Calls.id(9): TeamLogin(title: "x", protected: true, kind: "api_key", env: "EXAMPLE_API_KEY")] },
        ]
        for change in earlier {
            let refused = try Desk()
            try change(refused)
            #expect(Calls.words(await refused.answer(fields)) != nil)
            #expect(refused.clipboardReads == 0 && !refused.asked.contains("clipboard") && refused.looks.isEmpty)
        }
        let wrong = try Desk()
        #expect(await wrong.answer(Calls.key(from: "clipboard", env: "example")) == .refused(SaveSecret.envWord))
        #expect(await wrong.answer(fields, value) == .refused(SaveSecret.clipboardTakesNoPart))
        #expect(wrong.clipboardReads == 0)
        // What the read gives, when it gives no value.
        let over = value + String(repeating: " ", count: OwnerChannel.valueMax)
        let none: [SaveBotToken.Clipboard] = [.nothing, .text("short", count: 1), .text("example value-0123", count: 1),
                                              .text("\u{FEFF}" + value, count: 1), .text(over, count: 1), .text("", count: 1),
                                              .text(value + "\n", count: 1), .text("  " + value, count: 1),
                                              .text(value + " ", count: 1)]
        for copied in none {
            wrong.clipboard = copied
            #expect(await wrong.answer(fields) == .refused(SaveSecret.notOnClipboard))
        }
        wrong.clipboard = .notAllowed
        #expect(await wrong.answer(fields) == .refused(SaveSecret.clipboardDenied))
        wrong.clipboard = .busy
        #expect(await wrong.answer(fields) == .refused(SaveSecret.clipboardBusy))
        #expect(wrong.clipboardReads == none.count + 2 && wrong.asked.filter { $0 == "clipboard" }.count == none.count + 2)
        #expect(wrong.registers.isEmpty && wrong.clears.isEmpty && wrong.looks.isEmpty && !wrong.asked.contains("item"))
        #expect(wrong.table.state(of: Calls.id(1)) == nil)
        // The same call with a value in the clipboard then goes.
        wrong.clipboard = .text(value, count: 41)
        let then = await Calls.saved(wrong, fields)
        #expect(then.answer == Calls.done(1, then.reference, clipboard: "cleared"))
    }

    /// **A call that ended before or during the read sends nothing.** Before the read (its caller went away while
    /// the list was read, or before the call ran at all): no read, so no question of macOS that nobody waits for,
    /// and the words say that the call ended before the save began. During the read (macOS's question has no
    /// limit): the text that came is not used, and the words name the clipboard. Nothing begins, nothing is sent
    /// and nothing is cleared, and the same call with a caller then goes.
    @Test func aCallThatEndedBeforeOrDuringTheReadSendsNothing() async throws {
        let app = try Desk()
        app.cancelAt = "room"
        #expect(await Calls.call(app, fields) == .refused(SaveSecret.endedBeforeBegin))
        #expect(app.clipboardReads == 0 && app.asked.last == "room")
        app.cancelAt = nil
        let late = Task { await app.answer(fields) }
        late.cancel()
        #expect(await late.value == .refused(SaveSecret.endedBeforeBegin))
        #expect(app.clipboardReads == 0)
        app.cancelAt = "clipboard"
        #expect(await Calls.call(app, fields) == .refused(SaveSecret.endedDuringRead))
        #expect(app.clipboardReads == 1 && app.asked.last == "clipboard")
        #expect(app.registers.isEmpty && app.intakes.isEmpty && app.clears.isEmpty && app.looks.isEmpty)
        #expect(app.references.isEmpty && app.table.state(of: Calls.id(1)) == nil)
        app.cancelAt = nil
        let went = await Calls.saved(app, fields)
        #expect(went.answer == Calls.done(1, went.reference, clipboard: "cleared"))
        #expect(app.clipboardReads == 2 && app.clears.count == 1)
    }

    /// **The clipboard is cleared only after the save is done, and only at the read's count.** A refusal, a
    /// register with no answer, an intake that failed and a vault's refusal clear nothing. A save that is done
    /// clears with the count of its read: `cleared`. When something else wrote the clipboard since the read, the
    /// clear leaves it: `kept`. A save that is done at a later run clears then, with the count of the first
    /// call's read, and reads the clipboard no second time.
    @Test func theClipboardIsClearedOnlyAfterDoneAtTheReadsCount() async throws {
        let failures: [(String, (Desk) -> Void)] = [
            ("the hub refused the entry", { $0.registerAnswers = [OwnerSaveSecretSaveTests.hub(409)] }),
            ("no vault at the hub's step", { $0.registerAnswers = [OwnerSaveSecretSaveTests.hub(503)] }),
            ("a register with no answer", { $0.registerAnswers = [SaveBotToken.HubFailure.noAnswer] }),
            ("an intake that failed", { $0.intakeAnswers = [SaveBotToken.HubFailure.noAnswer] }),
            ("the vault refused", { $0.intakeAnswers = [OwnerSaveSecretSaveTests.hub(409)] }),
        ]
        for (name, change) in failures {
            let app = try Desk()
            change(app)
            #expect(Calls.words(await app.answer(fields)) != nil, "\(name)")
            #expect(app.clipboardReads == 1 && app.clears.isEmpty && !app.asked.contains("clear"), "\(name)")
        }
        let app = try Desk()
        let went = await Calls.saved(app, fields)
        #expect(went.answer == Calls.done(1, went.reference, clipboard: "cleared"))
        #expect(app.clears.map(\.0) == [41] && app.clears.map(\.1) == [true] && app.asked.last == "clear")
        // Something else wrote the clipboard between the read and the clear.
        let moved = try Desk()
        moved.clipboardCount = 42
        let kept = await Calls.saved(moved, fields)
        #expect(kept.answer == Calls.done(1, kept.reference, clipboard: "kept"))
        #expect(moved.clears.map(\.0) == [41] && moved.clears.map(\.1) == [false])
        // Done at the second run: one read, by the first call, and the clear with that read's count.
        for (count, word) in [(41, "cleared"), (42, "kept")] {
            let later = try Desk()
            later.registerAnswers = [SaveBotToken.HubFailure.noAnswer, nil]
            let first = await later.answer(fields)
            let reference = try #require(later.references.first)
            #expect(first == .refused(SaveSecret.registerNotKnown(reference, id: Calls.id(1))) && later.clears.isEmpty)
            later.clipboard = .text("other-" + "value-4567", count: 50)
            later.clipboardCount = count
            #expect(await later.answer(fields) == Calls.done(1, reference, clipboard: word))
            #expect(later.clipboardReads == 1 && later.clears.map(\.0) == [41] && later.clears.map(\.1) == [count == 41])
            #expect(later.registers.allSatisfy { $0.item["password"] == value })
            // The answer stays what it was: a repeat clears nothing again.
            #expect(await later.answer(fields) == Calls.done(1, reference, clipboard: word))
            #expect(later.clears.count == 1 && later.clipboardReads == 1)
        }
    }

    /// **A save that began while a call waited is found before the clipboard is read.** Two calls pass the first
    /// look at the table while neither has begun, and both wait in a read of the fleet (the vault's key, or the
    /// list). One reads the clipboard and begins. The other then looks at the table again, right before its own
    /// read, and reads nothing:
    /// - the same call (one id, the same fields): it joins the save, and answers as that save answers. The
    ///   clipboard was read ONE time, and one box was made;
    /// - a save that failed in the meantime and can go on: the join makes it go on, with no read;
    /// - another id: it is told that another save runs;
    /// - other fields under the id: it is refused.
    @Test func aSaveThatBeganWhileACallWaitedIsFoundBeforeTheClipboardIsRead() async throws {
        // The same call two times, held at the read of the key, and then at the read of the list.
        for wait in ["sealKey", "room"] {
            let app = try Desk()
            app.holdAt = [wait, "register"]
            let second = Calls.Call(app, fields)
            await Calls.until { app.holds(wait) == 1 }
            let first = Calls.Call(app, fields)
            await Calls.until { app.holds(wait) == 2 }
            #expect(app.clipboardReads == 0 && app.looks.isEmpty, "\(wait)")
            app.open(wait, 1)
            await Calls.until { app.holds("register") == 1 }
            #expect(app.clipboardReads == 1 && app.looks.count == 1 && app.table.state(of: Calls.id(1)) == .running(.registering))
            // The clipboard holds something else now, and macOS would ask again: the call that waited reads nothing.
            app.clipboard = .notAllowed
            app.open(wait, 0)
            await Calls.until { app.table.waiting == 2 }
            #expect(app.table.waiting == 2 && !second.came && !first.came, "\(wait)")
            #expect(app.clipboardReads == 1 && app.looks.count == 1 && app.references.count == 1, "\(wait)")
            #expect(app.asked.filter { $0 == "clipboard" }.count == 1 && app.asked.filter { $0 == "item" }.count == 1)
            app.holdAt = []
            app.open("register")
            let done = await first.ended()
            #expect(done == Calls.done(1, app.references.first ?? "", clipboard: "cleared"), "\(wait)")
            #expect(await second.ended() == done, "\(wait)")
            #expect(app.clipboardReads == 1 && app.registers.count == 1 && app.intakes.count == 1 && app.clears.count == 1)
            #expect(await app.boxesGone())
        }

        // A save that failed while the other call waited, and that can go on: the join makes it go on.
        let failed = try Desk()
        failed.registerAnswers = [SaveBotToken.HubFailure.noAnswer, nil]
        failed.holdAt = ["room"]
        let later = Calls.Call(failed, fields)
        await Calls.until { failed.holds("room") == 1 }
        let began = Calls.Call(failed, fields)
        await Calls.until { failed.holds("room") == 2 }
        failed.open("room", 1)
        let lost = await began.ended()
        #expect(lost == .refused(SaveSecret.registerNotKnown(failed.references.first ?? "", id: Calls.id(1))))
        #expect(failed.clipboardReads == 1 && failed.registers.count == 1 && failed.looks.first?.box?.holdsItem == true)
        failed.open("room", 0)
        #expect(await later.ended() == Calls.done(1, failed.references.first ?? "", clipboard: "cleared"))
        #expect(failed.clipboardReads == 1 && failed.looks.count == 1 && failed.references.count == 1)
        #expect(failed.registers.count == 2 && failed.registers.allSatisfy { $0.reference == failed.references.first })

        // Another id: another save runs, and this call reads nothing.
        let other = try Desk()
        other.holdAt = ["room", "register"]
        let waits = Calls.Call(other, Calls.key(2, from: "clipboard", env: "OTHER_API_KEY"))
        await Calls.until { other.holds("room") == 1 }
        let runs = Calls.Call(other, fields)
        await Calls.until { other.holds("room") == 2 }
        other.open("room", 1)
        await Calls.until { other.holds("register") == 1 }
        other.open("room", 0)
        #expect(await waits.ended() == .refused(SaveSecret.busy))
        #expect(other.clipboardReads == 1 && other.looks.count == 1 && other.table.state(of: Calls.id(2)) == nil)
        other.holdAt = []
        other.open("register")
        #expect(await runs.ended() == Calls.done(1, other.references.first ?? "", clipboard: "cleared"))
        #expect(other.clipboardReads == 1 && other.registers.count == 1)

        // Other fields under the id: refused, and nothing read.
        let mixed = try Desk()
        mixed.holdAt = ["room", "register"]
        let changed = Calls.Call(mixed, Calls.key(1, from: "clipboard", url: "https://api.example.com"))
        await Calls.until { mixed.holds("room") == 1 }
        let own = Calls.Call(mixed, fields)
        await Calls.until { mixed.holds("room") == 2 }
        mixed.open("room", 1)
        await Calls.until { mixed.holds("register") == 1 }
        mixed.open("room", 0)
        #expect(await changed.ended() == .refused(SaveSecret.otherFields))
        #expect(mixed.clipboardReads == 1 && mixed.looks.count == 1)
        mixed.holdAt = []
        mixed.open("register")
        #expect(await own.ended() == Calls.done(1, mixed.references.first ?? "", clipboard: "cleared"))
    }

    /// **A join reads no clipboard.** The caller's repeat of a save from the clipboard joins the save that the
    /// table has: while it runs, after a failure that it goes on from, and after its end. The clipboard was read
    /// once, by the first call, and what it holds now is not looked at.
    @Test func aJoinReadsNoClipboard() async throws {
        let app = try Desk()
        app.holdAt = ["register"]
        let first = Calls.Call(app, fields)
        await Calls.until { app.holds("register") == 1 }
        #expect(app.clipboardReads == 1)
        // The clipboard holds something else now, and macOS would ask again: the repeat does not read it.
        app.clipboard = .notAllowed
        let joined = Calls.Call(app, fields)
        await Calls.until { app.table.waiting == 2 }
        #expect(app.table.waiting == 2 && app.clipboardReads == 1 && app.looks.count == 1)
        app.holdAt = []
        app.open("register")
        let done = await first.ended()
        #expect(done == Calls.done(1, app.references.first ?? "", clipboard: "cleared"))
        #expect(await joined.ended() == done)
        #expect(await app.answer(fields) == done)
        #expect(app.clipboardReads == 1 && app.clears.count == 1 && app.registers.count == 1)
        #expect(app.registers.first?.item["password"] == value)
        // A new save under another id reads it, and is told what the read says.
        #expect(await app.answer(Calls.key(2, from: "clipboard", env: "OTHER_API_KEY")) == .refused(SaveSecret.clipboardDenied))
        #expect(app.clipboardReads == 2)
    }
}
