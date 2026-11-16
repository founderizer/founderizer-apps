import Foundation

// **The checks of a save of a new secret that has no form on the screen** (the tool `save_secret` of the owner's
// own agent; the secrets plan, `agent-install-secrets-plan.md`, step E). They are the checks that Add secret makes
// itself (`SecretEntryView`: the vault's key as the form opens, and the list's read at Save), each as one pure rule
// over values that were read already. So the tool asks the same questions as the form, and a test asks them with no
// hub. Nothing here reads the hub, and nothing here keeps a value. Below the two checks: the secret of the tool's
// fields as the form's own type holds it (`SecretOfFields`), and the hub's features as a save may read them
// (`ShownFeatures`).

/// **The key that a new secret is sealed to, or why nothing is sealed now.** A value is sealed only to the central
/// vault's own key, and only while that key is the one that this Mac pinned at the vault's Set up: a hub that is
/// broken into can name a key of its own, and a value sealed to it would be the attacker's.
public enum VaultSealKey: Equatable, Sendable {
    /// The central vault's key, which is the one that this Mac pinned. The vault holds a recovery key.
    case key(String)
    /// No central vault answers the hub now: the hub does not serve the feature, it gave no reading of the vault, the
    /// reading names no fleet, or the vault's last status was not good.
    case noVault
    /// The vault answers, and this Mac pinned no key for this hub and this fleet: the vault's Set up on this Mac
    /// makes the pin.
    case noPin
    /// The vault answers, this Mac has a pin, and the vault's key is not that one: another key, or no key that can
    /// be read. Apart from `noPin`, because the owner's step is another one: a key that changed is looked at first,
    /// and a new Set up to get past it would put a new pin in the old one's place.
    case otherKey
    /// The vault answers with the pinned key and holds no recovery key yet. The hub takes no new secret then
    /// (`hub.py` `central_refusal`), so nothing is sealed for a save that the hub refuses.
    case noRecovery

    /// - `reading`: `GET /ui/vault` (`VaultClient.reading`), or nil from a hub that does not serve it.
    /// - `served`: whether the hub's `ui_features` name `CentralVault.feature`, which they do only while the hub's
    ///   last reading of the vault was good and recent.
    /// - `pin`: the key that this Mac pinned for this hub and this fleet, or nil. **The tool takes the pin as the
    ///   form does** (`SecretEntryView.start`): through the reading's `fleetID`, with
    ///   `CentralVaultPins.recipient(hub:fleet:)`. A pin is kept under a fleet's id, so a reading that names no fleet
    ///   has no pin to look for. Such a reading is "the vault does not answer", as in the form, and neither "no pin"
    ///   nor "another key": this rule says so itself, whatever pin the caller gives with it.
    ///
    /// The order: no vault, then no pin, then another key, then no recovery key. A vault that does not answer says
    /// nothing about its key; with no pin, no key of the vault can be the pinned one; and a vault with another key is
    /// not the owner's, whatever it says of a recovery key.
    public static func of(_ reading: VaultReading?, served: Bool, pin: String?) -> VaultSealKey {
        guard served, let reading, reading.fleetID != nil, let central = reading.central, central.ok else { return .noVault }
        guard let pin else { return .noPin }
        guard let recipient = reading.trusted(pin: pin) else { return .otherKey }
        guard central.recovery != nil else { return .noRecovery }
        return .key(recipient)
    }
}

/// **Whether the hub's list of secrets takes one new entry of this name.** The tool saves only a new secret: a name
/// that the list has is never replaced and never saved a second time, because nobody is there to read the form's
/// line about it and to press Save again.
public enum SecretRoom: Equatable, Sendable {
    /// Nothing of this name, and the list has room: the entry can go in.
    case free
    /// The list has a secret of this name: an API key of this variable name (one, or more from before the list
    /// refused a second one), or a login of this title.
    case held
    /// The list has `LoginSecret.maxCatalog` entries and takes no more.
    case full
    /// The hub gave no list of secrets (`TeamSnapshot.logins` is nil).
    case unread

    /// - `title`, `kind`: the new secret's name as the list shows it (`LoginSecret.title`) and its kind.
    /// - `logins`: the hub's list (`TeamSnapshot.logins`), or nil from a hub that gave none.
    /// - `but`: the reference of this save's own entry, or nil before the save has one. A save that goes on after a
    ///   lost answer can find its own entry in the list: that entry is this very secret and no other one, so it
    ///   holds no name against the save (`SecretNameHeld.of`), and a list that is full with it has room for it. So
    ///   a list is full only for a reference that is new to it.
    ///
    /// The name comes before the room, as in the form: a name that the list has is refused as held also when the
    /// list is full.
    public static func of(title: String, kind: LoginSecret.Kind, logins: [String: TeamLogin]?, but: String?) -> SecretRoom {
        guard let logins else { return .unread }
        switch SecretNameHeld.of(title, kind: kind, in: logins, but: but) {
        case .none: break
        case .key, .twice, .second: return .held
        }
        let isThere = but.map { logins[$0] != nil } ?? false
        return isThere || logins.count < LoginSecret.maxCatalog ? .free : .full
    }
}

/// **The secret of a save's fields, as the form's own type holds it** (`LoginSecret`): the one place that makes that
/// type for the tool `save_secret`. Three readers ask it, and all three must read one and the same secret: the check
/// of the fields alone (`name`), the maker of the item (`item`), and the address of the hub's step (`address`). The
/// fields are plain values, because the tool's own types are in a library that FleetCore does not link. It holds no
/// value: a value comes in for one call and stays in none.
public struct SecretOfFields: Equatable, Sendable {
    /// A secret's name in the hub's list: its title, and for an API key its variable name.
    public struct Name: Equatable, Sendable {
        public let title: String
        public let variable: String?
    }

    public let kind: LoginSecret.Kind
    /// An API key's variable name. A login has none.
    public let env: String?
    /// A login's sign-in page, or an API key's service address, which it can be without.
    public let url: String?
    /// A login's user name. An API key has none.
    public let username: String?

    public init(kind: LoginSecret.Kind, env: String? = nil, url: String? = nil, username: String? = nil) {
        self.kind = kind
        self.env = env
        self.url = url
        self.username = username
    }

    /// The form's own type with these fields and with no value: no password, no key and no seed.
    public var secret: LoginSecret {
        var secret = LoginSecret()
        secret.kind = kind
        secret.url = url ?? ""
        secret.username = username ?? ""
        secret.env = env ?? ""
        return secret
    }

    /// **The secret's name, or nil when the form's own type does not take the fields.** That type has no check of
    /// the fields alone (its `problem` wants a value), so it is asked with a stand-in for the value: a text that is
    /// no secret and that the type takes as a password, which no rule of a field reads.
    ///
    /// **The title is read only after that check.** For an address in which the type reads no host, its title is
    /// the WHOLE address, with the path and the query, and a title goes into the hub's list, its git history and its
    /// log. The type refuses such an address, so a refused secret has no name here. An empty stand-in fails safe:
    /// the type then takes no fields at all.
    public func name(standIn: String) -> Name? {
        var asked = secret
        asked.password = standIn
        guard asked.problem == nil else { return nil }
        return Name(title: asked.title, variable: asked.variable)
    }

    /// **The item of the secret with this value**: the bytes that the vault keeps (`LoginSecret.value()`), with the
    /// text as its password or its key, or nil when the type does not take the secret with this value. The text is
    /// taken as it is. The bytes are made for this call, and nothing here keeps a reference to them: the caller is
    /// their one holder and wipes them.
    public func item(value: String) -> Data? {
        var whole = secret
        whole.password = value
        return try? whole.value()
    }

    /// **The address that goes with the entry in the hub's step**, by the form's own rule
    /// (`SecretCommand.address(for:features:)`): only for an API key, only the scheme, the host and the port of an
    /// https address, and only to a hub whose features name its table of well-known services. nil for a login, always.
    public func address(features: [String]?) -> String? {
        SecretCommand.address(for: secret, features: features)
    }
}

/// **The hub's features as a save may read them**: what the app's reading shows now, only while that reading is
/// still of the hub and the database that the save sends with. A save keeps its hub and its database for its later
/// runs, and the app can show another hub or another generation by then: the features of that one say nothing about
/// the hub that the save sends to.
///
/// **nil says one thing only: the app's reading moved.** The app shows another hub, another database or no state.
/// No address goes with an entry then, and a read of the vault's key answers that the reading moved, and not that
/// no vault is served, which nothing says then. A hub that names no features at all, while the app still shows it,
/// is the empty list and not nil: that hub serves no vault and has no table for an address.
public enum ShownFeatures {
    /// - `features`: the `ui_features` of the app's reading now, or nil from a hub that names none.
    /// - `hub`, `database`: the hub and the database of that reading; the database is nil while the app has no state.
    /// - `sendsTo`: the hub and the database that the save sends with.
    public static func of(_ features: [String]?, hub: URL, database: String?,
                          sendsTo place: (hub: URL, database: String)) -> [String]? {
        guard hub == place.hub, database == place.database else { return nil }
        return features ?? []
    }
}
