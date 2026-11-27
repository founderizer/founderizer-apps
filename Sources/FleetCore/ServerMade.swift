import CryptoKit
import Foundation

/// **The record `server-made`: one server that a client made at a provider, signed by that client** (F17 design A,
/// Setup's piece SP1; the owner's rule of 22 November 2026, "my mac is just a client ... we can't rely on the current
/// mac!"). This Mac's own records of the servers that it made (`BuildRecord`, `MadeServers`) are the one proof that a
/// server of the account is this fleet's, so that "Start again" deletes it (`StartAgain.proven`), and they lived on this
/// Mac only. The hub now keeps a copy of each, as a statement that the Mac that made the server signed with its owner
/// key (`POST /ui/servers/made`), so that another device, and later the fleet's keeper, can read them.
///
/// **The hub's copy proves nothing by itself** (the validator's N8): a hub that is broken into can write the id of
/// another server of the same provider project into any list it serves, and a delete by that id would remove a server
/// that is not this fleet's. So a reader counts a record only when a key of its own anchors signed its exact text
/// (`counted`): it takes the key from its anchors by the record's `by`, and never the `key` that the hub's row carries.
/// Until the vault's list of devices (design A, P1) the one anchor is this Mac's own owner key, of the fleet that this
/// Mac pinned for the hub's address (`pinnedFleet`), never of a fleet that only the hub names.
///
/// **In SP1 no server is listed or deleted by a record of the hub**: "Start again" goes on with this Mac's own records,
/// and the one reader here is the sweep, which asks what the hub lacks (`sweep`). A record says that its client made
/// the server, and not that the server is the fleet's still: it has no end yet.
///
/// The statement is the canonical text of `OwnerStatement`, with `kind`, `fleet`, `at`, `v` and four fields of its own,
/// and nothing free: `machine` (the server's name), `provider`, `id` (the provider's own id of the server) and `use`.
public enum ServerMade {
    /// The hub's feature: it keeps the records (`POST /ui/servers/made`) and serves them (`GET /ui/servers/made`).
    public static let feature = "server_made"
    public static let kind = "server-made"
    /// The longest statement that a reader looks at: the four fields at their longest are far below it.
    static let longest = 4096

    /// **What one record says**: a server by the provider's own id, its name, and what it was made for.
    public struct Fields: Hashable, Sendable {
        /// The server's name, as the hub takes a new server's name (`Servers.namePattern`).
        public let machine: String
        public let provider: CloudProvider
        /// The provider's own id of the server (`CloudServers.isID`): the one thing that a delete names.
        public let id: String
        public let use: CloudServerUse

        /// The whole name must be of the pattern, as the hub's own check: Foundation's `$` ends only at the input's end today
        /// (no last line end passes), and the range check keeps that if the engine's rule changes.
        public init?(machine: String, provider: CloudProvider, id: String, use: CloudServerUse) {
            guard machine.range(of: Servers.namePattern, options: .regularExpression) == machine.startIndex..<machine.endIndex,
                  CloudServers.isID(id) else { return nil }
            self.machine = machine; self.provider = provider; self.id = id; self.use = use
        }

        /// The server at its provider, as `StartAgain.Server.id` names it: one record of each for each signer.
        public var server: String { "\(provider.rawValue)|\(id)" }
    }

    /// **The one name of a signer in a record**: SHA-256 of its key's 65 bytes (the uncompressed P-256 point, 0x04
    /// first), in lower-case hex, the form of a `client-end`'s `keys` in design A (section 1.2), as the vault confirmed
    /// on 23 November 2026. nil for a text that is not such a key in standard, padded base64. Every place that names a
    /// signer by its key goes through here, so a change of the form is this one function.
    public static func by(_ key: String) -> String? {
        guard let point = point(key) else { return nil }
        return SHA256.hash(data: point).map { String(format: "%02x", $0) }.joined()
    }

    /// The 65 bytes of a key in standard, padded base64 that is a point of the curve, or nil.
    private static func point(_ key: String) -> Data? {
        guard let raw = Data(base64Encoded: key), raw.base64EncodedString() == key, raw.count == 65, raw.first == 4,
              (try? P256.Signing.PublicKey(x963Representation: raw)) != nil else { return nil }
        return raw
    }

    /// The statement that a client signs for one server it made, in the fleet of `fleet` (the hub's `fleet_id()`).
    public static func statement(fleet: String, _ made: Fields, at: Int = OwnerStatement.now()) -> String {
        OwnerStatement.serverMade(fleet: fleet, made: made, at: at)
    }

    /// **The fields of a statement that is exactly a `server-made` of this fleet**, or nil: the text must be the
    /// canonical text that `statement` writes for the fields it holds, so a field more, another kind, another version,
    /// a value of another type and any other spelling of the same object are no record.
    public static func fields(of statement: String, fleet: String) -> Fields? {
        guard statement.utf8.count <= longest,
              let object = (try? JSONSerialization.jsonObject(with: Data(statement.utf8))) as? [String: Any],
              let machine = object["machine"] as? String,
              let provider = (object["provider"] as? String).flatMap({ CloudProvider(rawValue: $0) }),
              let id = object["id"] as? String, let use = (object["use"] as? String).flatMap({ CloudServerUse(rawValue: $0) }),
              let at = (object["at"] as? NSNumber)?.intValue, at >= 0,
              let made = Fields(machine: machine, provider: provider, id: id, use: use),
              Self.statement(fleet: fleet, made, at: at) == statement else { return nil }
        return made
    }

    /// **Whether `key` signed exactly this text**: ECDSA P-256 over SHA-256 of its UTF-8 bytes, DER, in standard,
    /// padded base64, as `vault.owner_signed` reads it. A base64 or a DER that is not in its one strict form is no
    /// signature, so this reader and the vault's take the same texts.
    public static func verifies(_ statement: String, signature: String, key: String) -> Bool {
        guard let point = point(key), let publicKey = try? P256.Signing.PublicKey(x963Representation: point),
              let der = Data(base64Encoded: signature), der.base64EncodedString() == signature,
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: der), parsed.derRepresentation == der else {
            return false
        }
        return publicKey.isValidSignature(parsed, for: Data(statement.utf8))
    }

    /// **The servers that the hub's records prove to this reader**: each record whose `by` names a key of `anchors`
    /// and whose text that key signed, as a `server-made` of this fleet. The key comes from the anchors, never from the
    /// record, whose `key` is the hub's word. One for each server, the first that counts.
    public static func counted(_ records: [Record], fleet: String, anchors: [String]) -> [Fields] {
        var keys: [String: String] = [:]
        for key in anchors { if let name = by(key), keys[name] == nil { keys[name] = key } }
        var seen = Set<String>(), proven: [Fields] = []
        for record in records {
            guard let key = keys[record.by], verifies(record.statement, signature: record.signature, key: key),
                  let made = fields(of: record.statement, fleet: fleet), seen.insert(made.server).inserted else { continue }
            proven.append(made)
        }
        return proven
    }

    /// **One record as the hub keeps it** (`GET /ui/servers/made`): the statement, its signature and the key that the
    /// sender named, with that key's `by` and the hub's time of the write. Only `statement` and `signature` count, and
    /// `by` only to find a key of the reader's own anchors.
    public struct Record: Decodable, Equatable, Sendable {
        public let statement: String
        public let signature: String
        public let key: String
        public let by: String
        public let received: Double

        public init(statement: String, signature: String, key: String, by: String, received: Double) {
            self.statement = statement; self.signature = signature; self.key = key; self.by = by; self.received = received
        }
    }

    /// `GET /ui/servers/made`: the records of this hub generation, the fleet's id, and `swept`: the `by` of each key
    /// whose client said that it moved its files' records (`POST /ui/servers/made/swept`). A client believes it only
    /// beside a record of its own key (`ServerMade.sweep`): the word alone is a hub that lost the records.
    public struct Listing: Decodable, Sendable {
        public let db: String
        public let fleet: String
        public let records: [Record]
        public let swept: [String]

        /// The answer is of this hub generation, and of a size that a hub writes.
        public func validate(database: String) throws {
            guard db == database, CentralVault.isFleet(fleet), records.count <= 8192, swept.count <= 8192 else {
                throw HubError.invalidResponse
            }
        }
    }

    /// **A statement that this Mac signed**: the text, its signature and the public half of the key that signed it.
    /// Nobody who reads or writes this value can make one, so it is kept in a file (`Statements`).
    public struct Signed: Codable, Hashable, Sendable {
        public let statement: String
        public let signature: String
        public let key: String
        /// The hub generation (`Listing.db`) and the start of the app (`thisStart`) in which the hub refused it for
        /// good (`refusal`): it is not sent again in that start to that generation, and it is at the next start or to
        /// the next generation, which can be a hub that a release fixed or a restore brought back.
        public var refusedIn: String?

        public init(statement: String, signature: String, key: String, refusedIn: String? = nil) {
            self.statement = statement; self.signature = signature; self.key = key; self.refusedIn = refusedIn
        }

        /// One server's statement, signed now with this Mac's owner key.
        public static func sign(_ made: Fields, fleet: String, key: any OwnerKey, at: Int = OwnerStatement.now()) throws -> Signed {
            let statement = ServerMade.statement(fleet: fleet, made, at: at)
            return Signed(statement: statement, signature: try key.sign(statement), key: key.publicKey)
        }
    }

    /// What a refusal of one statement says of it: the hub never takes this text (`forGood`), or it has no room for
    /// it now (`noRoom`, a 409 with no code). nil for an error that says nothing of the statement: the hub is away, it
    /// changed its generation, or it refuses this Mac.
    enum Refusal { case forGood, noRoom }

    static func refusal(_ error: any Error) -> Refusal? {
        guard case .refusal(let refused)? = error as? HubError else { return nil }
        switch refused.status {
        case 400, 413, 422: return .forGood
        case 409 where refused.code == nil: return .noRoom
        default: return nil
        }
    }

    /// **Whether a provider's list that did not come says nothing yet** (`ServerMade.kept`): true for an error of the
    /// moment, as no answer, a wait that the provider asks for, an answer of its own (a 5xx comes as `refused`) or one
    /// that this app does not read; false only when the provider's token is gone or refused, which no later read
    /// changes until the owner gives another.
    public static func listWaits(_ error: any Error) -> Bool {
        switch error as? CloudError {
        case .noToken?, .notAToken?, .tokenNotAccepted?, .readOnlyToken?: false
        default: true
        }
    }

    /// The hub's answer to `POST /ui/servers/made`: `kept` false when it held a record of the same server by the same
    /// signer already, which it keeps in place of this one.
    public struct Receipt: Decodable, Sendable {
        public let ok: Bool
        public let request_id: String
        public let kept: Bool
        public let by: String
    }
}

extension OwnerStatement {
    /// **A client made this server at its provider** (`ServerMade`): through `canonical`, as every statement of the
    /// owner's, with `kind`, `fleet`, `at`, `v` and the four fields of the record.
    public static func serverMade(fleet: String, made: ServerMade.Fields, at: Int = now()) -> String {
        canonical(["v": .number(1), "kind": .text(ServerMade.kind), "fleet": .text(fleet), "machine": .text(made.machine),
                   "provider": .text(made.provider.rawValue), "id": .text(made.id), "use": .text(made.use.rawValue),
                   "at": .number(at)])
    }
}

extension HubClient {
    /// The session of this file's read, made as the client's own (`HubClient.shared`): no cookie, no cache, no
    /// redirect, and this Mac's key for the hub (`hubData`).
    private static let madeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// `GET /ui/servers/made` (feature `server_made`): the records of this hub generation. Each is the hub's word
    /// until a key of the reader's own anchors checks it (`ServerMade.counted`).
    public func madeServers(hub: URL, database: String) async throws -> ServerMade.Listing {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/servers/made"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        guard let url = parts.url else { throw HubError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.madeSession.hubData(for: request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(.read(status: response.statusCode, body: data)) }
        guard data.count <= 8_388_608 else { throw HubError.invalidResponse }
        let listing = try JSONDecoder().decode(ServerMade.Listing.self, from: data)
        try listing.validate(database: database)
        return listing
    }

    /// `POST /ui/servers/made` (feature `server_made`): the hub keeps this signed statement for every device of the
    /// fleet. It checks the form and the signature against the key that it names, which proves nothing to a reader
    /// (`ServerMade.counted`): it keeps the hub's list clean. A second record of the same server by the same key is
    /// kept as the first (`kept` false), so a send whose answer was lost is safe to send again.
    public func keepMadeServer(hub: URL, database: String, client: String, requestID: UUID = UUID(),
                               signed: ServerMade.Signed) async throws -> ServerMade.Receipt {
        guard let by = ServerMade.by(signed.key) else { throw HubError.invalidResponse }
        let receipt = try JSONDecoder().decode(ServerMade.Receipt.self, from: await ownerCommand(
            "ui/servers/made", hub: hub, database: database, client: client, requestID: requestID,
            fields: ["statement": signed.statement, "signature": signed.signature, "key": signed.key]))
        guard receipt.ok, receipt.request_id.lowercased() == requestID.uuidString.lowercased(), receipt.by == by else {
            throw HubError.invalidResponse
        }
        return receipt
    }

    /// `POST /ui/servers/<server>/install-ended {address}` (feature `server_made`): the hub keeps the mark that this
    /// Mac's install of the server reached its last step at that address (`ServerEntry.install_ended`). A plain mark
    /// that proves nothing (`InstallEnds`); the hub takes only the server's own address.
    public func keepInstallEnded(hub: URL, database: String, client: String, requestID: UUID = UUID(), server: String,
                                 address: String) async throws {
        guard server.range(of: Servers.namePattern, options: .regularExpression) != nil
                || server.range(of: Servers.machinePattern, options: .regularExpression) != nil,
              !address.isEmpty, address.utf8.count <= 253 else { throw HubError.invalidResponse }
        struct Answer: Decodable { let ok: Bool; let request_id: String; let server: String }
        let answer = try JSONDecoder().decode(Answer.self, from: await ownerCommand(
            "ui/servers/\(server)/install-ended", hub: hub, database: database, client: client, requestID: requestID,
            fields: ["address": address]))
        guard answer.ok, answer.request_id.lowercased() == requestID.uuidString.lowercased(), answer.server == server else {
            throw HubError.invalidResponse
        }
    }

    /// `POST /ui/servers/made/swept {by}`: the client whose key has this `by` moved its files' records, so it reads
    /// them no more (`Listing.swept`). The hub takes it only for a key that it holds a record of.
    public func keepMadeSwept(hub: URL, database: String, client: String, requestID: UUID = UUID(),
                              by: String) async throws {
        guard by.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw HubError.invalidResponse }
        let receipt = try JSONDecoder().decode(ServerMade.Receipt.self, from: await ownerCommand(
            "ui/servers/made/swept", hub: hub, database: database, client: client, requestID: requestID,
            fields: ["by": by]))
        guard receipt.ok, receipt.request_id.lowercased() == requestID.uuidString.lowercased(), receipt.by == by else {
            throw HubError.invalidResponse
        }
    }
}
