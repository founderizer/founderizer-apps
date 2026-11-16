import Foundation
import Testing
@testable import FleetCore

/// The two checks of a save of a new secret with no form on the screen (`SecretSaveChecks.swift`): the key that the
/// value is sealed to, and the room that the hub's list has for the entry. Synthetic values only: the keys are the
/// public keys of the other vault tests, and each name is an example.
struct SecretSaveChecksTests {
    static let vaultKey = CentralVaultPlanTests.vaultKey
    static let otherKey = CentralVaultTests.recipient
    static let fleet = CentralVaultTests.fleet

    /// One reading of `GET /ui/vault`, as the hub writes it. `fleet`: the fleet's id as the hub and the vault both
    /// name it, or nil for a reading that names no fleet.
    static func reading(central: Bool = true, ok: Bool = true, recipient: String? = vaultKey,
                        recovery: String? = otherKey, fleet: String? = SecretSaveChecksTests.fleet) throws -> VaultReading {
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

    // MARK: the key that a value is sealed to

    /// The one good case: the hub serves the vault, the vault answers with the key that this Mac pinned, and it
    /// holds a recovery key.
    @Test func theKeyIsThePinnedOneOfAVaultThatAnswers() throws {
        #expect(VaultSealKey.of(try Self.reading(), served: true, pin: Self.vaultKey) == .key(Self.vaultKey))
    }

    /// No vault answers: the hub does not name the feature, it gave no reading, the reading has no vault, or the
    /// vault's status is not good. A pin and a recovery key change nothing then.
    @Test func noVaultAnswers() throws {
        #expect(VaultSealKey.of(try Self.reading(), served: false, pin: Self.vaultKey) == .noVault)
        #expect(VaultSealKey.of(nil, served: true, pin: Self.vaultKey) == .noVault)
        #expect(VaultSealKey.of(try Self.reading(central: false), served: true, pin: Self.vaultKey) == .noVault)
        #expect(VaultSealKey.of(try Self.reading(ok: false), served: true, pin: Self.vaultKey) == .noVault)
        // Before the other three answers: a vault that does not answer says nothing about its key or this Mac's pin.
        #expect(VaultSealKey.of(try Self.reading(ok: false, recovery: nil), served: true, pin: nil) == .noVault)
        #expect(VaultSealKey.of(try Self.reading(ok: false), served: true, pin: Self.otherKey) == .noVault)
        #expect(VaultSealKey.of(nil, served: false, pin: nil) == .noVault)
    }

    /// **A reading that names no fleet is "the vault does not answer"**, as in the form: a pin is kept under a
    /// fleet's id, so there is none to look for, and that is neither "no pin" nor "another key". The rule says so
    /// whatever pin the caller gives.
    @Test func aReadingThatNamesNoFleetIsNoVault() throws {
        let nameless = try Self.reading(fleet: nil)
        #expect(nameless.fleetID == nil && nameless.central?.ok == true && nameless.central?.recipient == Self.vaultKey)
        #expect(VaultSealKey.of(nameless, served: true, pin: nil) == .noVault)
        #expect(VaultSealKey.of(nameless, served: true, pin: Self.vaultKey) == .noVault)
        #expect(VaultSealKey.of(nameless, served: true, pin: Self.otherKey) == .noVault)
        // A fleet id that is no fleet id is none.
        #expect(VaultSealKey.of(try Self.reading(fleet: "0F1E"), served: true, pin: Self.vaultKey) == .noVault)
        #expect(try Self.reading().fleetID == Self.fleet)
    }

    /// **This Mac pinned no key**: the vault answers, and there is no pin to hold its key to. Its own answer, apart
    /// from another key: the owner's step is the vault's Set up on this Mac. Before the vault's key and its recovery
    /// key are looked at: with no pin, no key can be the pinned one.
    @Test func thisMacPinnedNoKey() throws {
        #expect(VaultSealKey.of(try Self.reading(), served: true, pin: nil) == .noPin)
        #expect(VaultSealKey.of(try Self.reading(recipient: nil), served: true, pin: nil) == .noPin)
        #expect(VaultSealKey.of(try Self.reading(recovery: nil), served: true, pin: nil) == .noPin)
        #expect(VaultSealKey.of(try Self.reading(recipient: nil, recovery: nil), served: true, pin: nil) == .noPin)
    }

    /// The vault answers, this Mac has a pin, and the vault's key is not that one: another key, or no key that can
    /// be read. Nothing is sealed to a key that the hub alone names.
    @Test func anotherKeyThanThePinnedOne() throws {
        #expect(VaultSealKey.of(try Self.reading(), served: true, pin: Self.otherKey) == .otherKey)
        #expect(VaultSealKey.of(try Self.reading(recipient: nil), served: true, pin: Self.vaultKey) == .otherKey)
        #expect(VaultSealKey.of(try Self.reading(recipient: "age1notakey"), served: true, pin: "age1notakey") == .otherKey)
        #expect(VaultSealKey.of(try Self.reading(recipient: Self.otherKey), served: true, pin: Self.vaultKey) == .otherKey)
        // Before the recovery key: a vault with another key is not the owner's, whatever else it says.
        #expect(VaultSealKey.of(try Self.reading(recovery: nil), served: true, pin: Self.otherKey) == .otherKey)
    }

    /// **The order of the five answers**, one fault more at each step: no vault, no pin, another key, no recovery
    /// key, the key.
    @Test func theFiveAnswersInTheirOrder() throws {
        let worst = try Self.reading(ok: false, recipient: Self.otherKey, recovery: nil)
        #expect(VaultSealKey.of(worst, served: true, pin: nil) == .noVault)
        let answers = try Self.reading(recipient: Self.otherKey, recovery: nil)
        #expect(VaultSealKey.of(answers, served: true, pin: nil) == .noPin)
        #expect(VaultSealKey.of(answers, served: true, pin: Self.vaultKey) == .otherKey)
        #expect(VaultSealKey.of(answers, served: true, pin: Self.otherKey) == .noRecovery)
        #expect(VaultSealKey.of(try Self.reading(recipient: Self.otherKey), served: true, pin: Self.otherKey) == .key(Self.otherKey))
    }

    /// The pinned vault holds no recovery key yet: the hub would refuse the new entry, so nothing is sealed.
    @Test func noRecoveryKeyYet() throws {
        #expect(VaultSealKey.of(try Self.reading(recovery: nil), served: true, pin: Self.vaultKey) == .noRecovery)
        // A recovery key that cannot be read is none.
        #expect(VaultSealKey.of(try Self.reading(recovery: "age1notakey"), served: true, pin: Self.vaultKey) == .noRecovery)
    }

    // MARK: the room in the list

    static let first = "bws://11111111-2222-4333-8444-555555555551"
    static let second = "bws://11111111-2222-4333-8444-555555555552"
    static let third = "bws://11111111-2222-4333-8444-555555555553"
    static let own = "bws://11111111-2222-4333-8444-55555555555f"
    static let key = TeamLogin(title: "EXAMPLE_API_KEY", protected: true, kind: "api_key", env: "EXAMPLE_API_KEY")
    static let renamed = TeamLogin(title: "Example, the old one", protected: true, kind: "api_key", env: "EXAMPLE_API_KEY")
    static let shop = TeamLogin(title: "shop.example.com · owner", protected: true, kind: "login")
    static let list = [first: key, third: shop]

    /// A list of `count` entries, each a key of its own name.
    static func many(_ count: Int) -> [String: TeamLogin] {
        var list: [String: TeamLogin] = [:]
        for index in 0..<count {
            let name = "FILLER_\(index)_KEY"
            list[String(format: "bws://00000000-0000-4000-8000-%012x", index)] =
                TeamLogin(title: name, protected: true, kind: "api_key", env: name)
        }
        return list
    }

    @Test func aNewNameInAListWithRoomIsFree() {
        #expect(SecretRoom.of(title: "NEW_API_KEY", kind: .apiKey, logins: Self.list, but: nil) == .free)
        #expect(SecretRoom.of(title: "other.example.com · owner", kind: .login, logins: Self.list, but: nil) == .free)
        #expect(SecretRoom.of(title: "NEW_API_KEY", kind: .apiKey, logins: [:], but: nil) == .free)
        // A key with the title of a login is no second key.
        #expect(SecretRoom.of(title: "shop.example.com · owner", kind: .apiKey, logins: Self.list, but: nil) == .free)
    }

    /// A hub that gave no list is not an empty list: nothing says whether the name is there.
    @Test func aHubWithNoListIsUnread() {
        #expect(SecretRoom.of(title: "NEW_API_KEY", kind: .apiKey, logins: nil, but: nil) == .unread)
        #expect(SecretRoom.of(title: "shop.example.com · owner", kind: .login, logins: nil, but: Self.own) == .unread)
    }

    /// A name that the list has: one key of the variable name (also under another title), two of them, or a login of
    /// the title. The tool never replaces and never adds a second one.
    @Test func aNameThatTheListHasIsHeld() {
        #expect(SecretRoom.of(title: "EXAMPLE_API_KEY", kind: .apiKey, logins: Self.list, but: nil) == .held)
        #expect(SecretRoom.of(title: "EXAMPLE_API_KEY", kind: .apiKey, logins: [Self.second: Self.renamed], but: nil) == .held)
        #expect(SecretRoom.of(title: "EXAMPLE_API_KEY", kind: .apiKey,
                              logins: [Self.first: Self.key, Self.second: Self.renamed], but: nil) == .held)
        #expect(SecretRoom.of(title: "shop.example.com · owner", kind: .login, logins: Self.list, but: nil) == .held)
        // A login with the title of a key is a second entry of that title.
        #expect(SecretRoom.of(title: "EXAMPLE_API_KEY", kind: .login, logins: Self.list, but: nil) == .held)
    }

    /// **The save's own entry is left out.** A save that goes on after a lost answer finds its entry in the list: it
    /// holds no name against itself. Another entry of the same name still does.
    @Test func theSavesOwnEntryIsLeftOut() {
        var list = Self.list
        list[Self.own] = TeamLogin(title: "NEW_API_KEY", protected: false, kind: "api_key", env: "NEW_API_KEY")
        #expect(SecretRoom.of(title: "NEW_API_KEY", kind: .apiKey, logins: list, but: nil) == .held)
        #expect(SecretRoom.of(title: "NEW_API_KEY", kind: .apiKey, logins: list, but: Self.own) == .free)
        #expect(SecretRoom.of(title: "EXAMPLE_API_KEY", kind: .apiKey, logins: list, but: Self.own) == .held)
        list[Self.own] = Self.shop
        #expect(SecretRoom.of(title: "shop.example.com · owner", kind: .login, logins: list, but: Self.own) == .held)
        #expect(SecretRoom.of(title: "shop.example.com · owner", kind: .login,
                              logins: [Self.own: Self.shop], but: Self.own) == .free)
        // A reference that the list does not have changes nothing.
        #expect(SecretRoom.of(title: "EXAMPLE_API_KEY", kind: .apiKey, logins: Self.list, but: Self.own) == .held)
    }

    /// **Full only for a reference that is new to the list.** The list takes `LoginSecret.maxCatalog` entries: one
    /// less has room, and a full list still has room for the entry that is in it already.
    @Test func aFullListTakesNoNewReference() {
        let most = LoginSecret.maxCatalog
        #expect(most == 256)
        #expect(SecretRoom.of(title: "NEW_API_KEY", kind: .apiKey, logins: Self.many(most - 1), but: nil) == .free)
        #expect(SecretRoom.of(title: "NEW_API_KEY", kind: .apiKey, logins: Self.many(most), but: nil) == .full)
        #expect(SecretRoom.of(title: "new.example.com · owner", kind: .login, logins: Self.many(most), but: nil) == .full)
        #expect(SecretRoom.of(title: "NEW_API_KEY", kind: .apiKey, logins: Self.many(most + 1), but: nil) == .full)
        // A reference of its own that the list does not have is a new one.
        #expect(SecretRoom.of(title: "NEW_API_KEY", kind: .apiKey, logins: Self.many(most), but: Self.own) == .full)
        var withOwn = Self.many(most - 1)
        withOwn[Self.own] = TeamLogin(title: "NEW_API_KEY", protected: false, kind: "api_key", env: "NEW_API_KEY")
        #expect(withOwn.count == most)
        #expect(SecretRoom.of(title: "NEW_API_KEY", kind: .apiKey, logins: withOwn, but: Self.own) == .free)
        #expect(SecretRoom.of(title: "NEW_API_KEY", kind: .apiKey, logins: withOwn, but: nil) == .held)
    }

    /// The name comes before the room, as in the form: a full list with the name says held.
    @Test func aNameIsHeldBeforeTheListIsFull() {
        #expect(SecretRoom.of(title: "FILLER_7_KEY", kind: .apiKey, logins: Self.many(LoginSecret.maxCatalog), but: nil) == .held)
    }

    // MARK: the secret of the tool's fields

    /// A stand-in for a value, as the tool's wiring gives it: no secret, and a text that the type takes as a password.
    static let standIn = String(repeating: "x", count: 8)
    /// A made-up value of no service, in two parts: no literal here has the form of a real key.
    static let value = "example-" + "value-0123"
    static let shopLogin = SecretOfFields(kind: .login, url: "https://shop.example.com/login", username: "owner@example.com")
    static let serviceKey = SecretOfFields(kind: .apiKey, env: "EXAMPLE_API_KEY", url: "https://api.example.com/v1?mark=1")

    private static func fields(of item: Data?) -> [String: String]? {
        item.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
    }

    /// **The fields make the form's own type, with no value**, and the name is the type's own: "host · user name"
    /// for a login, the variable name for a key.
    @Test func theFieldsMakeTheFormsOwnSecretWithNoValue() {
        var login = LoginSecret()
        login.kind = .login
        login.url = "https://shop.example.com/login"
        login.username = "owner@example.com"
        #expect(Self.shopLogin.secret == login)
        var key = LoginSecret()
        key.kind = .apiKey
        key.env = "EXAMPLE_API_KEY"
        key.url = "https://api.example.com/v1?mark=1"
        #expect(Self.serviceKey.secret == key)
        for secret in [Self.shopLogin.secret, Self.serviceKey.secret] {
            #expect(secret.password.isEmpty && secret.totp.isEmpty)
        }
        #expect(Self.shopLogin.name(standIn: Self.standIn)
                == SecretOfFields.Name(title: "shop.example.com · owner@example.com", variable: nil))
        #expect(Self.serviceKey.name(standIn: Self.standIn)
                == SecretOfFields.Name(title: "EXAMPLE_API_KEY", variable: "EXAMPLE_API_KEY"))
        // A key with no address is a key.
        #expect(SecretOfFields(kind: .apiKey, env: "EXAMPLE_API_KEY").name(standIn: Self.standIn)
                == SecretOfFields.Name(title: "EXAMPLE_API_KEY", variable: "EXAMPLE_API_KEY"))
        // The stand-in is in no name.
        #expect(Self.shopLogin.name(standIn: Self.standIn)?.title.contains(Self.standIn) == false)
    }

    /// **A secret that the form's own type refuses has no name and no item.** The address has a label that is no
    /// valid name in its coding: the type reads no host in it, and the type's title of it is the WHOLE address, with
    /// its path. So the name is read only from a secret that the type took, and such an address gets nil.
    @Test func aSecretThatTheTypeRefusesHasNoNameAndNoItem() {
        let site = "https://xn--a.example.com/pathmark"
        // What the rule keeps out of the hub's list.
        var typed = LoginSecret()
        typed.kind = .login
        typed.url = site
        typed.username = "owner"
        typed.password = Self.standIn
        #expect(typed.problem != nil && typed.title.contains("pathmark"))
        let login = SecretOfFields(kind: .login, url: site, username: "owner")
        #expect(login.name(standIn: Self.standIn) == nil && login.item(value: Self.value) == nil)
        let key = SecretOfFields(kind: .apiKey, env: "EXAMPLE_API_KEY", url: site)
        #expect(key.name(standIn: Self.standIn) == nil && key.item(value: Self.value) == nil)
        #expect(key.address(features: [SecretCommand.keyTableFeature]) == nil)
        // Each other set of fields that the type refuses: a login with no user name or no address, a key with no
        // variable name, with one that is no variable name, or with a name that a session sets itself.
        for refused in [SecretOfFields(kind: .login, url: "https://shop.example.com/login"),
                        SecretOfFields(kind: .login, username: "owner"),
                        SecretOfFields(kind: .login, url: "shop.example.com", username: "owner"),
                        SecretOfFields(kind: .apiKey),
                        SecretOfFields(kind: .apiKey, env: "1EXAMPLE_KEY"),
                        SecretOfFields(kind: .apiKey, env: "FLEET_EXAMPLE_KEY"),
                        SecretOfFields(kind: .apiKey, env: "EXAMPLE_API_KEY", url: "api.example.com")] {
            #expect(refused.name(standIn: Self.standIn) == nil, "\(refused)")
            #expect(refused.item(value: Self.value) == nil, "\(refused)")
        }
        // An empty stand-in fails safe: the type then takes no fields at all.
        #expect(Self.shopLogin.name(standIn: "") == nil && Self.serviceKey.name(standIn: "") == nil)
    }

    /// **The item is the type's own bytes, with the value as it is**: nothing is taken off the text and nothing is
    /// added, and the helper keeps no value.
    @Test func theItemIsTheTypesOwnBytesWithTheValueAsItIs() throws {
        let item = try #require(Self.shopLogin.item(value: Self.value))
        #expect(Self.fields(of: item) == ["username": "owner@example.com", "password": Self.value,
                                          "url": "https://shop.example.com/login"])
        var typed = Self.shopLogin.secret
        typed.password = Self.value
        #expect(try item == typed.value())
        #expect(Self.fields(of: Self.serviceKey.item(value: Self.value))
                == ["username": "", "password": Self.value, "url": "https://api.example.com/v1?mark=1"])
        // A key with no address has none in its item.
        #expect(Self.fields(of: SecretOfFields(kind: .apiKey, env: "EXAMPLE_API_KEY").item(value: Self.value))
                == ["username": "", "password": Self.value])
        // As it is: white space at an end stays in the item. (The tool's own form refuses such a text before.)
        let spaced = " " + Self.value + "\n"
        #expect(Self.fields(of: Self.serviceKey.item(value: spaced))?["password"] == spaced)
        // No value, no item. And the fields hold no value after a call.
        #expect(Self.serviceKey.item(value: "") == nil && Self.shopLogin.item(value: "") == nil)
        #expect(Self.serviceKey.secret.password.isEmpty && Self.shopLogin.secret.password.isEmpty)
    }

    /// **An API key's address goes by the form's own rule, and a login gets none.** Only the scheme, the host and
    /// the port of an https address, and only to a hub that names its table of well-known services.
    @Test func aKeysAddressGoesByTheFormsRuleAndALoginGetsNone() {
        let features = [SecretCommand.keyTableFeature]
        #expect(Self.serviceKey.address(features: features) == "https://api.example.com")
        #expect(Self.serviceKey.address(features: features)
                == SecretCommand.address(for: Self.serviceKey.secret, features: features))
        #expect(SecretOfFields(kind: .apiKey, env: "EXAMPLE_API_KEY", url: "https://example.com:8443/a/b?c=d")
            .address(features: features) == "https://example.com:8443")
        // A hub without the feature, an address that is not https, and a key with no address: none.
        #expect(Self.serviceKey.address(features: []) == nil && Self.serviceKey.address(features: nil) == nil)
        #expect(Self.serviceKey.address(features: [CentralVault.feature]) == nil)
        #expect(SecretOfFields(kind: .apiKey, env: "EXAMPLE_API_KEY", url: "http://api.example.com/v1")
            .address(features: features) == nil)
        #expect(SecretOfFields(kind: .apiKey, env: "EXAMPLE_API_KEY").address(features: features) == nil)
        // A login, never: also with the address of a service.
        #expect(Self.shopLogin.address(features: features) == nil)
        #expect(SecretOfFields(kind: .login, url: "https://api.example.com/v1", username: "owner")
            .address(features: features) == nil)
        // The hub's command takes the address that the rule gives.
        #expect(throws: Never.self) {
            try SecretCommand.add(requestID: UUID(), database: "gen-1", login: Self.own, title: "EXAMPLE_API_KEY",
                                  kind: .apiKey, variable: "EXAMPLE_API_KEY",
                                  address: Self.serviceKey.address(features: features), fingerprints: [])
        }
    }

    /// **The hub's features are read only while the app still shows the hub and the database that the save sends
    /// with.** Another hub, another generation or no state gives nil, and nil says only that: the app's reading
    /// moved. No address goes with the entry then, and the read of the key says that the reading moved, before the
    /// rule of the key is asked. A hub that names no features, while the app shows it, is the empty list: that one
    /// serves no vault, by the rule.
    @Test func theFeaturesAreReadOnlyWhileTheAppShowsTheSavesHubAndDatabase() throws {
        let hub = try #require(URL(string: "https://hub.example.com/"))
        let other = try #require(URL(string: "https://other.example.com/"))
        let features = [CentralVault.feature, SecretCommand.keyTableFeature]
        let shown = ShownFeatures.of(features, hub: hub, database: "gen-1", sendsTo: (hub, "gen-1"))
        #expect(shown == features)
        let moved = ShownFeatures.of(features, hub: other, database: "gen-1", sendsTo: (hub, "gen-1"))
        #expect(moved == nil)
        #expect(ShownFeatures.of(features, hub: hub, database: "gen-2", sendsTo: (hub, "gen-1")) == nil)
        #expect(ShownFeatures.of(features, hub: hub, database: nil, sendsTo: (hub, "gen-1")) == nil)
        #expect(ShownFeatures.of(nil, hub: other, database: "gen-1", sendsTo: (hub, "gen-1")) == nil)
        // Not moved, and no feature: the empty list, from a hub that names none as from one that names nothing.
        let noFeatures = ShownFeatures.of(nil, hub: hub, database: "gen-1", sendsTo: (hub, "gen-1"))
        #expect(noFeatures == [] && noFeatures != nil)
        #expect(ShownFeatures.of([], hub: hub, database: "gen-1", sendsTo: (hub, "gen-1")) == [])
        // What follows: a key's address only for the hub that the app shows.
        #expect(Self.serviceKey.address(features: shown) == "https://api.example.com")
        #expect(Self.serviceKey.address(features: moved) == nil && Self.serviceKey.address(features: noFeatures) == nil)
        // The rule of the key is asked only with the features of a hub that the app shows: with the feature, the
        // key; with none, no vault. For a reading that moved there is no list to ask the rule with.
        let reading = try Self.reading()
        #expect(VaultSealKey.of(reading, served: shown?.contains(CentralVault.feature) == true, pin: Self.vaultKey)
                == .key(Self.vaultKey))
        #expect(VaultSealKey.of(reading, served: noFeatures?.contains(CentralVault.feature) == true, pin: Self.vaultKey)
                == .noVault)
    }
}
