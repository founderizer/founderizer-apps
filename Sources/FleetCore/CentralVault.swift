import Foundation

/// **The fleet's central vault** (owner feature `central_vault`, UI-API 1.42): one vault on the hub's server that
/// holds every secret, and gives each server's vault only the secrets that the agents there hold grants for. It trusts
/// the hub as every vault does, except in the two things that would let a hub that is broken into take everything: it
/// seals a copy only to a server key the owner signed (a pin), and its backup only to a recovery key the owner signed.
/// This Mac holds the owner's key, installs the vault over the owner's own SSH connection, and signs those statements.
public enum CentralVault {
    /// The hub serves this feature only while its last reading of the central vault was good and recent.
    public static let feature = "central_vault"
    /// The hub's own machine, by the name the fleet gives it in `GET /ui/machines`: the manager's machine. A server's
    /// name is its name in Tailscale (the hub's `server_names`), so it is "hub" only on a fleet that never renamed it.
    public static func hubMachine(in machines: [MachineStatus]) -> String {
        machines.first(where: { $0.role == "manager" })?.machine ?? "hub"
    }

    /// A fleet's id, as the hub's `fleet_id()` writes it: 16 lower-case hex characters.
    public static func isFleet(_ text: String) -> Bool { text.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil }

    /// A machine name that a pin can carry, which is the vault's own rule.
    public static func isMachine(_ text: String) -> Bool { text.range(of: "^[a-z][a-z0-9-]{0,62}$", options: .regularExpression) != nil }

    /// An `age1…` recipient, or nil: a field the hub sends that is not one is read as missing.
    static func recipient(_ text: String?) -> String? { text.flatMap { AgeSeal.publicKey(of: $0) != nil ? $0 : nil } }

    /// The SHA-256 of a program, as the hub and the vault write it: 64 lower-case hex characters, or nil.
    static func program(_ text: String?) -> String? {
        text.flatMap { $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil ? $0 : nil }
    }
}

/// The central vault's own status, as the hub last read it (the vault's `status` answer). It holds keys and counts,
/// never a value.
public struct CentralStatus: Decodable, Equatable, Sendable {
    public struct Pin: Decodable, Equatable, Sendable {
        public let recipient: String?
        public let at: Double?
    }
    /// One grant that the owner signed and has not taken back (owner feature `signed_grants`): the vault may seal this
    /// secret to the vault of this machine, for this agent.
    public struct Grant: Decodable, Equatable, Sendable {
        public let login: String
        public let agent: String
        public let machine: String
    }
    public let ok: Bool
    /// The vault's own key: a new secret is sealed to it, and only this vault opens what is.
    public let recipient: String?
    public let store_recipient: String?
    public let fleet: String?
    public let owner_keys: Int?
    /// The servers the owner signed, by machine.
    public let pins: [String: Pin]
    /// The key of the owner's recovery code, or nil while the vault has none and so makes no backup.
    public let recovery: String?
    /// The grants the owner signed, and the secrets he signed into the grantable pool. A vault older than signed grants
    /// gives neither, and that reads as none.
    public let grants: [Grant]
    public let pool: [String]
    public let items: Int?
    /// The SHA-256 of the program the vault runs (vault.py's own file), or nil from a vault that does not say.
    public let source: String?

    private enum Keys: String, CodingKey {
        case ok, recipient, store_recipient, fleet, owner_keys, pins, recovery, grants, pool, items, source
    }

    public init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: Keys.self)
        ok = (try? data.decodeIfPresent(Bool.self, forKey: .ok)) == true
        recipient = CentralVault.recipient(try? data.decodeIfPresent(String.self, forKey: .recipient))
        store_recipient = CentralVault.recipient(try? data.decodeIfPresent(String.self, forKey: .store_recipient))
        fleet = (try? data.decodeIfPresent(String.self, forKey: .fleet)).flatMap { CentralVault.isFleet($0) ? $0 : nil }
        owner_keys = try? data.decodeIfPresent(Int.self, forKey: .owner_keys)
        pins = ((try? data.decodeIfPresent([String: Lossy<Pin>].self, forKey: .pins)) ?? [:]).compactMapValues(\.value)
        recovery = CentralVault.recipient(try? data.decodeIfPresent(String.self, forKey: .recovery))
        grants = ((try? data.decodeIfPresent([Lossy<Grant>].self, forKey: .grants)) ?? []).compactMap(\.value)
            .filter { LoginSecret.isReference($0.login) }
        pool = ((try? data.decodeIfPresent([String].self, forKey: .pool)) ?? []).filter(LoginSecret.isReference)
        items = try? data.decodeIfPresent(Int.self, forKey: .items)
        source = CentralVault.program(try? data.decodeIfPresent(String.self, forKey: .source))
    }
}

/// The central vault's machine, which is the hub's own, as `GET /ui/vault` names it: its address and how the fleet
/// reaches it (its `access` record). No agent need run there, so `GET /ui/machines` may not name it at all.
public struct VaultHub: Decodable, Equatable, Sendable {
    public struct SSH: Decodable, Equatable, Sendable {
        public let user: String?
        public let port: Int?
    }
    public let machine: String
    public let address: String?
    public let ssh: SSH?

    /// The fleet's record of how it reaches the machine, read as `MachineReach` reads a machine's.
    public var reach: MachineReach { MachineReach(address: address, user: ssh?.user, port: ssh?.port) }
}

/// One machine with a worker or a lead, as the central vault sees it: the agent whose helper carries its copies, the
/// key its vault reports, the key the owner pinned for it, and why it gets nothing now.
public struct VaultMachine: Decodable, Equatable, Identifiable, Sendable {
    public let machine: String
    public let carrier: String?
    public let broker_recipient: String?
    public let pinned: String?
    public let matches: Bool
    public let missing: [String]
    public var id: String { machine }

    /// The central vault seals for this machine now: its vault reports a key, and the owner pinned that very key.
    public var isTrusted: Bool { carrier != nil && broker_recipient != nil && pinned == broker_recipient && matches }

    /// A machine whose key the owner can pin: its helper carries copies, and its vault reports its key.
    public var canBeTrusted: Bool { carrier != nil && broker_recipient != nil && CentralVault.isMachine(machine) }

    /// Why the central vault gives this machine nothing now, in one sentence: the missing pin first, for a machine
    /// that can have one, and otherwise the hub's own reason (`deposit_machines`).
    public var why: String {
        if canBeTrusted && pinned == nil { return "You have not trusted its vault yet." }
        if canBeTrusted && (pinned != broker_recipient || missing.contains("pin_mismatch")) {
            return "Its vault answers with another key than the one you trusted."
        }
        return missing.first { $0 != "not_pinned" && $0 != "pin_mismatch" }.map(Self.reason)
            ?? "Its vault gets nothing from the central vault now."
    }

    /// The hub's codes of what keeps a machine's vault from a copy now (`deposit_machines`), as facts.
    public static func reason(_ code: String) -> String {
        switch code {
        case "no_broker_access": return "No agent there uses its server's vault."
        case "no_vault_store": return "Its vault has no pinned key yet."
        case "agent_without_key": return "Its agent has no agent key."
        case "broker_status_unknown": return "Founderizer on it has not reported its vault in the last 10 minutes."
        case "vault_store_mismatch": return "Its vault answers with another key than the one you pinned. Look at that server first."
        case "broker_without_callers": return "Its vault is older than the vault that serves each agent of a server."
        case "helper_without_deposits": return "Founderizer on it is older than deliveries."
        case "broker_without_deposits":
            return "Its vault takes no copy yet. With the fleet's own store it needs the vault.py of this release on Linux (System status gives the line), or Founderizer Vault 0.3.0 on a Mac."
        default: return "Its vault takes no copy now."
        }
    }

    private enum Keys: String, CodingKey { case machine, carrier, broker_recipient, pinned, matches, missing }

    public init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: Keys.self)
        machine = try data.decode(String.self, forKey: .machine)
        carrier = try? data.decodeIfPresent(String.self, forKey: .carrier)
        broker_recipient = CentralVault.recipient(try? data.decodeIfPresent(String.self, forKey: .broker_recipient))
        pinned = CentralVault.recipient(try? data.decodeIfPresent(String.self, forKey: .pinned))
        matches = (try? data.decodeIfPresent(Bool.self, forKey: .matches)) == true
        missing = (try? data.decodeIfPresent([String].self, forKey: .missing)) ?? []
    }
}

/// `GET /ui/vault`: the central vault's status (nil while there is none), the hub's last word about reading it,
/// each machine's pin, and which secrets each machine holds now. `fleet` comes even without a central vault: the
/// fleet's id, which the owner's key and the pins are kept under. The hub names no path: the app installs the vault
/// from root's own clone at its one fixed place (`CentralVaultRemote.rootKit`). A field the app cannot read is left
/// out; nothing in it is a value.
public struct VaultReading: Decodable, Sendable {
    public let db: String
    public let fleet: String?
    public let central: CentralStatus?
    public let read_at: Double?
    public let error: String?
    public let machines: [VaultMachine]
    /// By machine: the references whose newest delivery there finished, with no withdrawal after it.
    public let held: [String: [String]]
    /// The SHA-256 of the `vault.py` of the release the hub runs, or nil from a hub that does not say.
    public let program: String?
    /// The central vault's machine, or nil from a hub that does not say: then it is the manager's, as before.
    public let hub: VaultHub?

    private enum Keys: String, CodingKey { case db, fleet, central, read_at, error, machines, held, program, hub }

    public init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: Keys.self)
        db = try data.decode(String.self, forKey: .db)
        fleet = (try? data.decodeIfPresent(String.self, forKey: .fleet)).flatMap { CentralVault.isFleet($0) ? $0 : nil }
        central = try? data.decodeIfPresent(CentralStatus.self, forKey: .central)
        read_at = try? data.decodeIfPresent(Double.self, forKey: .read_at)
        error = try? data.decodeIfPresent(String.self, forKey: .error)
        machines = ((try? data.decodeIfPresent([Lossy<VaultMachine>].self, forKey: .machines)) ?? []).compactMap(\.value)
        held = ((try? data.decodeIfPresent([String: [String]].self, forKey: .held)) ?? [:])
            .mapValues { $0.filter(LoginSecret.isReference) }
        program = CentralVault.program(try? data.decodeIfPresent(String.self, forKey: .program))
        hub = (try? data.decodeIfPresent(VaultHub.self, forKey: .hub)).flatMap { CentralVault.isMachine($0.machine) ? $0 : nil }
    }

    /// The central vault runs another program than the `vault.py` of the hub's release, as both of them say: the app
    /// brings it up to date by itself (`VaultPlan`). A side that says nothing is not behind.
    public var programBehind: Bool {
        guard let central, central.ok, let running = central.source, let release = program else { return false }
        return running != release
    }

    /// The fleet this reading is about: the hub's own word, else the vault's.
    public var fleetID: String? { fleet ?? central?.fleet }

    /// The central vault's key, only while the vault answers and the key is the one this Mac pinned at Set up: the
    /// one key Add secret seals to. Any other key, or none, leaves Add secret as it was.
    public func trusted(pin: String?) -> String? {
        guard let central, central.ok, let recipient = central.recipient, recipient == pin else { return nil }
        return recipient
    }
}

/// An entry of a list that cannot be read is left out, and the rest of the reading stays.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// The three owner commands of the central vault (owner commands with a `request_id`), sent at once and never kept in
/// the outbox, as the other commands of Add secret: the hub's receipt is the record. None of them carries a value.
public enum VaultCommand {
    /// `POST /ui/vault/intake`: the value of a secret of the catalog, sealed to the central vault's key.
    public static func intake(requestID: UUID, database: String, login: String, ciphertext: String) throws -> Data {
        guard LoginSecret.isReference(login), AgeSeal.isSealed(ciphertext), ciphertext.count <= AgeSeal.maxCopy else {
            throw HubError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: ["request_id": requestID.uuidString.lowercased(), "db": database,
                                                           "login": login, "ciphertext": ciphertext],
                                          options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// `POST /ui/vault/pin`, `/recovery` and `/grant`: one statement and the owner's signature of it, which the hub
    /// passes on to the vault as they are.
    public static func signed(requestID: UUID, database: String, statement: String, signature: String) throws -> Data {
        guard !statement.isEmpty, statement.utf8.count <= 1024, !statement.contains(where: \.isNewline),
              let der = Data(base64Encoded: signature), (8...80).contains(der.count) else { throw HubError.invalidResponse }
        return try JSONSerialization.data(withJSONObject: ["request_id": requestID.uuidString.lowercased(), "db": database,
                                                           "statement": statement, "signature": signature],
                                          options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// The receipt of `POST /ui/vault/intake`: `saved` is `new`, or `same` for the value that was there already.
public struct VaultIntakeReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let login: String
    public let saved: String?
}

/// The receipt of a signed statement: what the vault kept (`new`, `same`, `replaced` or `removed`).
public struct VaultStatementReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let kind: String?
    public let machine: String?
    public let recipient: String?
    public let login: String?
    public let agent: String?
    public let saved: String?
}

/// The five routes of the central vault.
public final class VaultClient: Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20      // the hub asks the vault, which answers within 10 seconds
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    /// `GET /ui/vault`, or nil from a hub that does not serve it (404): that hub has no central vault, and the app
    /// shows nothing new.
    public func reading(hub: URL, database: String) async throws -> VaultReading? {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/vault"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw HubError.refusal(response.statusCode, Self.words(data)) }
        guard data.count <= 1_048_576 else { throw HubError.invalidResponse }
        let reading = try JSONDecoder().decode(VaultReading.self, from: data)
        guard reading.db == database, Set(reading.machines.map(\.machine)).count == reading.machines.count else {
            throw HubError.invalidResponse
        }
        return reading
    }

    /// The sealed value of one secret that the catalog has, for the central vault. It keeps the value only when its
    /// fingerprints are the ones registered for that reference.
    public func intake(hub: URL, database: String, client: String, login: String, ciphertext: String,
                       requestID: UUID = UUID()) async throws -> VaultIntakeReceipt {
        let body = try VaultCommand.intake(requestID: requestID, database: database, login: login, ciphertext: ciphertext)
        let receipt = try JSONDecoder().decode(VaultIntakeReceipt.self, from: await command("ui/vault/intake", hub: hub, client: client, body: body))
        guard receipt.ok, receipt.request_id == requestID.uuidString.lowercased(), receipt.client == client, receipt.login == login else {
            throw HubError.invalidResponse
        }
        return receipt
    }

    /// A pin (or an unpin) of one server's vault key, signed by the owner.
    public func pin(hub: URL, database: String, client: String, statement: String, signature: String,
                    requestID: UUID = UUID()) async throws -> VaultStatementReceipt {
        try await signed("ui/vault/pin", hub: hub, database: database, client: client, statement: statement, signature: signature,
                         requestID: requestID)
    }

    /// The recovery key the central vault seals its backup to, signed by the owner.
    public func recovery(hub: URL, database: String, client: String, statement: String, signature: String,
                         requestID: UUID = UUID()) async throws -> VaultStatementReceipt {
        try await signed("ui/vault/recovery", hub: hub, database: database, client: client, statement: statement, signature: signature,
                         requestID: requestID)
    }

    /// A grant of one secret to one agent, its end, or the secret into the grantable pool or out of it, signed by the
    /// owner (owner feature `signed_grants`): the vault seals a copy only for what the owner signed.
    public func grant(hub: URL, database: String, client: String, statement: String, signature: String,
                      requestID: UUID = UUID()) async throws -> VaultStatementReceipt {
        try await signed("ui/vault/grant", hub: hub, database: database, client: client, statement: statement, signature: signature,
                         requestID: requestID)
    }

    /// The owner key's certificate of a phone's signing key (owner feature `door_calls`): `POST
    /// /ui/owner/devices/<device>/certify`.
    public func certifyDevice(hub: URL, database: String, client: String, device: String, statement: String,
                              signature: String, requestID: UUID = UUID()) async throws -> VaultStatementReceipt {
        try await signed("ui/owner/devices/\(device)/certify", hub: hub, database: database, client: client,
                         statement: statement, signature: signature, requestID: requestID)
    }

    /// `POST /ui/owner/devices/<device>/recovery` (owner feature `recovery_copy`, API 1.95): the recovery code, sealed to
    /// that phone's own recovery key (`RecoverySeal`). The hub carries the box until the phone takes it.
    public func recoveryCopy(hub: URL, database: String, client: String, device: String, sealed: String,
                             requestID: UUID = UUID()) async throws {
        guard OwnerDevices.isName(device) else { throw HubError.invalidResponse }
        let body = try JSONSerialization.data(withJSONObject: [
            "request_id": requestID.uuidString.lowercased(), "db": database, "sealed": sealed], options: [.sortedKeys])
        let receipt = try JSONDecoder().decode(VaultStatementReceipt.self,
                                               from: await command("ui/owner/devices/\(device)/recovery", hub: hub,
                                                                   client: client, body: body))
        guard receipt.ok, receipt.request_id == requestID.uuidString.lowercased(), receipt.client == client else {
            throw HubError.invalidResponse
        }
    }

    /// `POST /ui/door/mode` (owner feature `door_mode_set`, API 1.125): the owner's signed mode of one server, Auto or
    /// Full access, which the hub carries to the door. Throws `DoorModeCommand.Newer` when the hub carries a statement
    /// of that server that is as new or newer.
    public func doorMode(hub: URL, database: String, client: String, host: String, mode: DoorMode, at: Int,
                         statement: String, signature: String, requestID: UUID = UUID()) async throws -> DoorModeReceipt {
        var request = URLRequest(url: hub.appendingPathComponent("ui/door/mode"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try DoorModeCommand.body(requestID: requestID, database: database, host: host,
                                                    statement: statement, signature: signature)
        let (data, response) = try await session.data(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        if let newer = DoorModeCommand.newer(status: response.statusCode, body: data) { throw newer }
        guard response.statusCode == 200 else { throw HubError.refusal(response.statusCode, Self.words(data)) }
        return try DoorModeCommand.receipt(data, requestID: requestID, client: client, host: host, mode: mode, at: at)
    }

    private func signed(_ route: String, hub: URL, database: String, client: String, statement: String, signature: String,
                        requestID: UUID) async throws -> VaultStatementReceipt {
        let body = try VaultCommand.signed(requestID: requestID, database: database, statement: statement, signature: signature)
        let receipt = try JSONDecoder().decode(VaultStatementReceipt.self, from: await command(route, hub: hub, client: client, body: body))
        guard receipt.ok, receipt.request_id == requestID.uuidString.lowercased(), receipt.client == client else { throw HubError.invalidResponse }
        return receipt
    }

    private func command(_ route: String, hub: URL, client: String, body: Data) async throws -> Data {
        var request = URLRequest(url: hub.appendingPathComponent(route))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(response.statusCode, Self.words(data)) }
        return data
    }

    private static func words(_ data: Data) -> String {
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? HubError.unexplained
        return String(message.prefix(500))
    }
}

/// **The central vault's key as this Mac pinned it**, by hub address and fleet: the `recipient` that the install
/// printed on the hub's own machine, which reached this Mac over its own SSH connection and not through the hub. Add
/// secret seals to the central vault only while the hub names this same key, so a hub that is broken into cannot put
/// a vault of its own in its place. A public key, so this Mac's defaults are the place for it.
public enum CentralVaultPins {
    static let key = "centralVaultPins"

    public static func recipient(hub: URL, fleet: String, in defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: key) as? [String: String])?[name(hub, fleet)]
    }

    public static func pin(_ recipient: String, hub: URL, fleet: String, in defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        all[name(hub, fleet)] = recipient
        defaults.set(all, forKey: key)
    }

    private static func name(_ hub: URL, _ fleet: String) -> String { "\(hub.absoluteString)|\(fleet)" }
}

/// What the install of the central vault printed last: the vault's key and its fleet, its own reason for stopping, or
/// (the app's own install only) that the vault on that machine holds another owner key and was left as it is.
public enum CentralInstall: Equatable, Sendable {
    case installed(recipient: String, fleet: String)
    case refused(String)
    case otherOwner
}

/// **The two programs this Mac runs over the owner's own SSH connection** for the central vault, and how it reads
/// what they print. Both use the installer's own connection (`InstallPlan.arguments(for:)`) with one difference,
/// which is the point: `StrictHostKeyChecking=yes`. A pin is only as good as the machine it was read from, so a host
/// this Mac has not met before is refused here, where an install accepts it once.
public enum CentralVaultRemote {
    /// Where a server's own vault keeps its configuration (`vault.py`), whose `age_key` names its key file.
    public static let brokerConfig = "/etc/fleet-vault/vault.json"

    /// The arguments of `ssh` for one program on `target`: the installer's, with the host key checked strictly.
    public static func arguments(target: InstallTarget, program: String) -> [String] {
        InstallPlan(job: .join, target: target, steps: [], redactions: []).arguments(for: program)
            .map { $0 == "StrictHostKeyChecking=accept-new" ? "StrictHostKeyChecking=yes" : $0 }
    }

    /// **Root's own clone of the published repository on the hub's machine** (DevOps plan V2), at the revision of a
    /// release whose manifest a release key signed. The app runs the vault's install from here and from nowhere
    /// else: never from a folder that the hub's user can change, and never from a path that the hub names.
    public static let rootKit = "/usr/local/lib/founderizer-kit"

    /// The install, as root on the hub's own machine: the clone brought to the hub's newest signed release
    /// (`kit-clone`, which never takes an older one), then its `hubsetup.py central-vault` with the owner's public key.
    /// Running it again is how the vault is updated; it keeps the store and the vault's key. `keepOwner`: the app's
    /// own install, which leaves a vault that another Mac's key holds as it is (`hubsetup.py` prints
    /// `{"ok": false, "owner": "other"}`); without it the owner's own Set up takes the vault over with this key.
    /// nil for a key that is not one.
    public static func install(ownerKey: String, keepOwner: Bool) -> String? {
        guard let point = Data(base64Encoded: ownerKey), point.count == 65, point.first == 0x04 else { return nil }
        let program = "python3 \(rootKit)/hubsetup.py"
        return bridge() + "; \(program) kit-clone && \(program) central-vault --owner-key \(InstallPlan.quote(ownerKey))"
            + (keepOwner ? " --keep-owner" : "")
    }

    /// **The bridge across the key change of 4 November 2026** (PRODUCT.md 4.3): root's clone of a hub installed
    /// before that day has no `early-key.pub`, and its own `kit-clone` reads `release-key.pub` alone, which holds only
    /// the website's old key, so it refuses every release since. In such a clone only, this build's own release keys
    /// (`AppUpdate`: the approve key, the spare and the early key, never a key that the hub names) go into that file
    /// first, so the clone's own code checks the hub's signed release with them; its checkout then puts the release's
    /// own key files in their place. A clone of that release or later has `early-key.pub`, and the step does nothing.
    static func bridge(in kit: String = rootKit) -> String {
        let keys = (AppUpdate.shippedKeys + "\n" + AppUpdate.earlyKeys).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { Data(base64Encoded: $0)?.count == 32 }
        guard !keys.isEmpty else { return ":" }          // a build with no key writes no file: it would trust nothing
        let file = "\(kit)/release-key.pub"
        return "if test -d \(kit)/.git && ! test -e \(kit)/early-key.pub; then printf '%s\\n' "
            + keys.map { "'\($0)'" }.joined(separator: " ") + " > \(file) || exit 1; fi"
    }

    /// The read of one server's vault key: the path that its configuration names, and the one line of that file that
    /// is its public key. Only that line can leave the machine: `grep` prints a line that is a public key and
    /// nothing else, and the private key's own line never is one.
    public static let readBrokerKey = #"k=$(python3 -c 'import json; print(json.load(open("/etc/fleet-vault/vault.json"))["age_key"])')"#
        + #" && grep -m1 -E '^# public key: age1[0-9a-z]{58}$' "$k""#

    /// The read of a Mac's vault key: Founderizer Vault's own `status`, asked through its socket by the user it serves,
    /// with no `sudo`, and its key printed in the line that `brokerKey(in:)` reads. Only that public key leaves the Mac.
    public static let readMacVaultKey = #"python3 -c 'import json, os, socket; s = socket.socket(socket.AF_UNIX); s.settimeout(10); "#
        + #"s.connect(os.path.expanduser("~/Library/Application Support/AgentFleet/vault.sock")); "#
        + #"s.sendall(b"{\"v\": 2, \"op\": \"status\"}\n"); "#
        + ##"print("# public key: " + str(json.loads(s.makefile().readline()).get("recipient")))'"##

    /// The vault key in what `readBrokerKey` or `readMacVaultKey` printed, or nil when it printed none or more than one.
    public static func brokerKey(in output: String) -> String? {
        let keys = Set(output.split(separator: "\n").compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("# public key: ") else { return nil }
            return CentralVault.recipient(String(text.dropFirst("# public key: ".count)))
        })
        return keys.count == 1 ? keys.first : nil
    }

    /// The install's answer: its last line that is a JSON object with `ok`. Its other lines and anything the machine
    /// printed on standard error come before it.
    public static func installed(_ output: String) -> CentralInstall? {
        for line in output.split(separator: "\n").reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let ok = object["ok"] as? Bool else { continue }
            if !ok && object["owner"] as? String == "other" { return .otherOwner }
            guard ok else { return .refused((object["error"] as? String).map { String($0.prefix(300)) } ?? "It gave no reason.") }
            guard let recipient = CentralVault.recipient(object["recipient"] as? String),
                  let fleet = object["fleet"] as? String, CentralVault.isFleet(fleet) else {
                return .refused("It printed no vault key and no fleet that Founderizer can read.")
            }
            return .installed(recipient: recipient, fleet: fleet)
        }
        return nil
    }
}
