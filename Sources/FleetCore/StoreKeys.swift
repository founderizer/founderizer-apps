import CryptoKit
import Foundation

// MARK: a key for a cluster's store (the door's stage B, the Vault area's part, piece A-S1)

/// **`STORE_UUID`**: a lower-case UUID, the whole text. The one form of each id of Bitwarden Secrets Manager that this
/// app takes: an organization, a project and an item (`remote`). The app checks it in `NeedSecret.store`, on each id
/// of a store's answer, and on a `remote` that the hub gives, before each call that names it. So no text of a
/// manifest, of the hub or of an answer reaches the path of a call or a record.
public enum StoreUUID {
    public static func valid(_ text: String) -> Bool {
        StoreForm.whole(text, "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    }
}

/// The forms of the fields of a store key, as the hub's `DOOR_STORE_KEY` writes them.
enum StoreForm {
    /// True when all of `text` matches `pattern`: ICU's `$` also matches before one final line break, so the pattern
    /// is anchored with `\A` and `\z`.
    static func whole(_ text: String, _ pattern: String) -> Bool {
        text.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
    }

    /// `door_targets.REPO`: owner/name.
    static func repo(_ text: String) -> Bool { whole(text, "[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}") }

    /// The file of a store's manifest: parts of `[A-Za-z0-9._-]` with `/` between them, no `..`, the ending `.yaml`,
    /// `.yml` or `.json`, at most 200 characters.
    static func path(_ text: String) -> Bool {
        text.count <= 200 && !text.contains("..") && whole(text, "[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*\\.(?:yaml|yml|json)")
    }

    /// A Kubernetes name of at most 63 characters (an RFC 1123 label): a store's name and a namespace.
    static func kubernetes(_ text: String) -> Bool { whole(text, "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?") }

    /// The Secret's name: the stem, a dash and the hub's 6 characters.
    static func secretName(_ text: String) -> Bool { whole(text, "[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?-[a-z0-9]{6}") }

    /// An agent's name, as the door's file takes it.
    static func agent(_ text: String) -> Bool { whole(text, "[a-z0-9][a-z0-9-]{0,62}") }

    static let kinds: Set<String> = ["ClusterSecretStore", "SecretStore"]
    static let provider = "bitwardensecretsmanager"
    static let regions: Set<String> = ["us", "eu"]

    /// A signed statement: one line of at most 4096 characters.
    static func statement(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 4096 && !text.contains(where: { $0.isNewline })
    }

    /// A signature: standard base64, padded, of at most 256 characters (a DER signature of P-256 has 72 bytes at most).
    static func signature(_ text: String) -> Bool {
        text.count <= 256 && whole(text, "[A-Za-z0-9+/]+={0,2}") && Data(base64Encoded: text)?.base64EncodedString() == text
    }
}

/// One value of a store part, as JSON gives it.
public enum StoreValue: Decodable, Equatable, Sendable {
    case text(String)
    case number(Int)
    /// Any other JSON value: `null`, a boolean, a fraction, a list or an object.
    case other

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let text = try? value.decode(String.self) { self = .text(text) }
        else if let number = try? value.decode(Int.self) { self = .number(number) }
        else { self = .other }
    }

    var text: String? { if case .text(let text) = self { return text }; return nil }
    var number: Int? { if case .number(let number) = self { return number }; return nil }
}

/// What a store part is made of: an object of JSON values whose fields all pass their forms, or nothing.
public protocol StorePartValue: Equatable, Sendable {
    init?(fields: [String: StoreValue])
}

/// **A store part of a request or of a key, as this app reads it**: whole, with each field in its form, or broken.
/// A broken part gives no form at all, and never the form of a plain key: else a store request is saved as a plain
/// key, which no store gets.
public enum StorePart<Value: StorePartValue>: Decodable, Equatable, Sendable {
    case whole(Value)
    case broken

    public var value: Value? { if case .whole(let value) = self { return value }; return nil }

    public init(from decoder: Decoder) throws {
        guard let fields = try? decoder.singleValueContainer().decode([String: StoreValue].self),
              let value = Value(fields: fields) else { self = .broken; return }
        self = .whole(value)
    }
}

/// **The record of an item that the store has** (a `made` row of the hub's `store_keys`): the Needs-you item that
/// asked for it, the id of the item in the store, and the owner's signed statement of the record. A request with
/// `failed` and `logins[ref].store` of `GET /ui/team` carry it.
public struct StoreKeyMade: Equatable, Sendable {
    public let need: Int
    public let remote: String
    public let statement: String
    public let signature: String

    init(need: Int, remote: String, statement: String, signature: String) {
        self.need = need; self.remote = remote; self.statement = statement; self.signature = signature
    }
}

/// **A key for one workload of a cluster, as the hub's spec names it** (`spec["store"]`, `need_view`'s
/// `secret.store`, `logins[ref].store`): the GitOps repository and the file of the store's manifest, the store, the
/// namespace and the name of the Secret, and the store's Bitwarden region, organization and write project. Each field
/// is in its form, or the part is broken.
public struct StoreKeyTarget: StorePartValue {
    public let repo: String
    public let path: String
    /// `ClusterSecretStore` or `SecretStore`.
    public let storeKind: String
    public let store: String
    public let namespace: String
    /// The Secret's name: the stem, a dash and 6 characters.
    public let name: String
    /// `bitwardensecretsmanager`, the one provider that the Mac writes.
    public let provider: String
    /// `us` or `eu`: Bitwarden's own address pair.
    public let region: String
    public let organization: String
    /// The project that the Mac writes: the store's own (Whole project), or a project of its own (Own project).
    public let project: String
    /// The record of the item, for a key that the store has; nil for a first request.
    public let made: StoreKeyMade?

    /// Only `init(fields:)` makes one outside this module, so each target that the app uses passed its forms.
    init(repo: String, path: String, storeKind: String, store: String, namespace: String, name: String,
         provider: String = "bitwardensecretsmanager", region: String, organization: String, project: String,
         made: StoreKeyMade? = nil) {
        self.repo = repo; self.path = path; self.storeKind = storeKind; self.store = store; self.namespace = namespace
        self.name = name; self.provider = provider; self.region = region; self.organization = organization
        self.project = project; self.made = made
    }

    public init?(fields: [String: StoreValue]) {
        func text(_ key: String) -> String? { fields[key]?.text }
        guard let repo = text("repo"), StoreForm.repo(repo),
              let path = text("path"), StoreForm.path(path),
              let storeKind = text("store_kind"), StoreForm.kinds.contains(storeKind),
              let store = text("store"), StoreForm.kubernetes(store),
              let namespace = text("namespace"), StoreForm.kubernetes(namespace),
              let name = text("name"), StoreForm.secretName(name),
              text("provider") == StoreForm.provider,
              let region = text("region"), StoreForm.regions.contains(region),
              let organization = text("organization"), StoreUUID.valid(organization),
              let project = text("project"), StoreUUID.valid(project) else { return nil }
        // The record's four fields come all together or not at all.
        let recordKeys = ["need", "remote", "statement", "signature"]
        var made: StoreKeyMade?
        if recordKeys.contains(where: { fields[$0] != nil }) {
            guard let need = fields["need"]?.number, need > 0,
                  let remote = text("remote"), StoreUUID.valid(remote),
                  let statement = text("statement"), StoreForm.statement(statement),
                  let signature = text("signature"), StoreForm.signature(signature) else { return nil }
            made = StoreKeyMade(need: need, remote: remote, statement: statement, signature: signature)
        }
        self.init(repo: repo, path: path, storeKind: storeKind, store: store, namespace: namespace, name: name,
                  region: region, organization: organization, project: project, made: made)
    }
}

/// **The store of a writer card** (`spec["store_writer"]`, `secret.store_writer`): the Bitwarden region and
/// organization, and the project that the cluster's store reads. The writer key that the owner gives on such a card
/// stays in this Mac's keychain.
public struct StoreWriterTarget: StorePartValue {
    public let provider: String
    public let region: String
    public let organization: String
    /// The store's own project.
    public let project: String

    init(provider: String = "bitwardensecretsmanager", region: String, organization: String, project: String) {
        self.provider = provider; self.region = region; self.organization = organization; self.project = project
    }

    public init?(fields: [String: StoreValue]) {
        guard fields["provider"]?.text == StoreForm.provider,
              let region = fields["region"]?.text, StoreForm.regions.contains(region),
              let organization = fields["organization"]?.text, StoreUUID.valid(organization),
              let project = fields["project"]?.text, StoreUUID.valid(project) else { return nil }
        self.init(region: region, organization: organization, project: project)
    }
}

/// **Where the writer key of a cluster's store is kept** (service `com.founderizer.store-write`): the Bitwarden
/// token with which this Mac writes one project, on this Mac only, not synchronized. The hub, the central vault and
/// the list of secrets never get it.
public enum StoreWriterKeychain {
    public static let item = FleetKeychainItem(service: "com.founderizer.store-write", label: "cluster store key")

    /// The account of one store's writer key: `<fleet>|bitwardensecretsmanager|<organization>|<the store's project>`.
    public static func account(fleet: String, organization: String, storeProject: String) -> String {
        "\(fleet)|bitwardensecretsmanager|\(organization)|\(storeProject)"
    }
}

extension OwnerStatement {
    /// **The owner's record of an item in a cluster's store** (the door's `store_keys`): the item `remote` of the store
    /// holds the key that the Needs-you item `need` of `agent` asked for, as the Secret `namespace/name` of the store
    /// `store_kind` `store` of the GitOps repository `repo`. The Mac signs it only for an item that the store confirmed
    /// to its own write: the id in the answer of its create call, or an item whose project, name and note it read and
    /// whose update answered 200. The hub checks its form; the Mac's door round and the door check its signature.
    public static func storeKey(fleet: String, need: Int, agent: String, repo: String, storeKind: String, store: String,
                                namespace: String, name: String, remote: String, at: Int) -> String {
        canonical(["v": .number(1), "kind": .text("store-key"), "fleet": .text(fleet), "need": .number(need),
                   "agent": .text(agent), "repo": .text(repo), "store_kind": .text(storeKind), "store": .text(store),
                   "namespace": .text(namespace), "name": .text(name), "remote": .text(remote), "at": .number(at)])
    }
}

/// **One record of the door's `store_keys`** (`GET /ui/door`, and the list in an agent's GitOps target of the door's
/// file): the eight fields of the Door area's pass and the owner's signed statement of them. Ten fields in all.
public struct StoreKeyRecord: Codable, Equatable, Sendable {
    public let repo: String
    public let store_kind: String
    public let store: String
    public let remote: String
    public let namespace: String
    public let name: String
    public let agent: String
    public let need: Int
    public let statement: String
    public let signature: String

    public init(repo: String, store_kind: String, store: String, remote: String, namespace: String, name: String,
                agent: String, need: Int, statement: String, signature: String) {
        self.repo = repo; self.store_kind = store_kind; self.store = store; self.remote = remote
        self.namespace = namespace; self.name = name; self.agent = agent; self.need = need
        self.statement = statement; self.signature = signature
    }

    /// **Whether the door round writes this record into the GitOps target `repo` of `agent`**: the record names that
    /// agent and that repository; each field is in its form; the statement is the owner's statement of exactly these
    /// fields for `fleet`, with nothing more; and `ownerKey` (the base64 of this Mac's owner key, as `OwnerKey`
    /// gives it) signed it. So a row that the hub made up, changed or moved to another agent, repository, namespace or
    /// item stays out of the door's file.
    public func kept(ownerKey: String, fleet: String, agent: String, repo: String) -> Bool {
        guard self.agent == agent, self.repo == repo, StoreForm.agent(agent), StoreForm.repo(repo),
              StoreForm.kinds.contains(store_kind), StoreForm.kubernetes(store), StoreForm.kubernetes(namespace),
              StoreForm.secretName(name), StoreUUID.valid(remote), need > 0, StoreForm.statement(statement),
              let object = (try? JSONSerialization.jsonObject(with: Data(statement.utf8))) as? [String: Any],
              let number = object["at"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let at = Int(exactly: number.doubleValue), at >= 0 else { return false }
        let expected = OwnerStatement.storeKey(fleet: fleet, need: need, agent: agent, repo: repo, storeKind: store_kind,
                                               store: store, namespace: namespace, name: name, remote: remote, at: at)
        return expected == statement && Self.signed(statement, signature: signature, key: ownerKey)
    }

    /// True when `key` (base64 of the 65-byte point) signed exactly these statement bytes: the signature is the
    /// standard base64, padded, of the DER form, over SHA-256 of the statement's UTF-8 bytes.
    static func signed(_ statement: String, signature: String, key: String) -> Bool {
        guard let raw = Data(base64Encoded: signature), raw.base64EncodedString() == signature,
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: raw),
              let point = Data(base64Encoded: key),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: point) else { return false }
        return publicKey.isValidSignature(parsed, for: Data(statement.utf8))
    }
}
