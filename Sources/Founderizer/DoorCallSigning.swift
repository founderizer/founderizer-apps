import FleetCore
import Foundation

/// **The owner's signed yes to a door call** (owner feature `door_calls`, DevOps plan 5.4, decisions D11 and D22).
///
/// The DevOps door refuses a call that is the owner's: a delete of what no agent made through the door, an AWS delete,
/// or a host's `run`, a root script with no box. The manager takes it to the owner as a Needs-you item that names the
/// call's hash, and the item's first option is the yes. When he presses it, this Mac signs that yes with the owner key
/// that signs his grants, and the answer carries the statement. The door reads it from the hub and checks the signature against the owner key in its
/// own access file, so the hub can hold a yes back and forge none. Nothing shows: a hub without `door_calls`, an item
/// with no door call, another option, or a Mac with no owner key for this fleet sends the answer as before, and the
/// door then refuses the call again.
///
/// The door's card of a refused `run` (owner feature `door_modes`, the owner's "Yes, as shown" of 11 November 2026)
/// has a second answer, Full access on its server: this Mac signs that server's mode with the same key, and the door
/// then lets every later root script there through.
///
/// **The Mac signs Run it once only for the script that its card shows** (review point 5.6 of 11 November 2026, API
/// 1.125). On the door's card of a run, the hash that this Mac signs is the one that it computed itself from the card's
/// server and script (`DoorCall.checked`). When the card carries no script, or its script is not the one of the hash
/// that the hub gave, nothing is signed and nothing is sent: the saved-request line says why, in one line.
///
/// **A server's mode from its own row** (owner feature `door_mode_set`, API 1.125; the owner's "Yes, as shown" of 11
/// November 2026 to the row "Managed by <agent>" with Auto and Full access): `setMode` signs the mode with the same
/// key and sends it to `POST /ui/door/mode`. No view calls it yet.
@MainActor
enum DoorCallSigning {
    static let feature = "door_calls"
    static let modes = "door_modes"
    /// The hub takes a server's signed mode with no Needs-you item, and gives each server's mode in `/ui/servers`.
    static let modeSet = "door_mode_set"

    /// What the owner's press of one option of an item carries.
    enum Approval: Equatable {
        /// The answer goes as it is: an item with no door call, another option, a hub without the feature, or a Mac
        /// with no owner key of this fleet (the hub then says that the yes needs this Mac's signature).
        case none
        case signed(statement: String, signature: String)
        /// This Mac does not sign, and the answer is not sent: the line says why.
        case refused(String)
    }

    static func approval(for need: OwnerNeed, choice: Int, store: FleetStore, hub: URL,
                         database: String) async -> Approval {
        let features = store.state?.ui_features ?? []
        var make: ((String) -> String)?
        if choice == 0, let call = need.door_call, features.contains(feature) {
            var signs = call
            if let host = need.door_host {      // the door's card of a run: the hash of what the card shows
                switch DoorCall.checked(title: need.title, answers: need.options ?? [], host: host, call: call,
                                        script: need.door_script, details: need.details,
                                        words: [need.why, need.todo]) {
                case .success(let computed): signs = computed
                case .failure(.noScript) where !features.contains(modeSet): return .refused(DoorCall.olderHub)
                case .failure(let why): return .refused(why.line(by: need.by.agentLabel))
                }
            }
            make = { OwnerStatement.doorCall(fleet: $0, need: need.id, call: signs) }
        } else if choice == 1, need.door_call != nil, let host = need.door_host, features.contains(modes) {
            // Full access is signed only on the door's own card of that server: its title and its three answers
            // name it, so the option that he pressed says "Full access on <server>" for the server that is signed.
            guard DoorCall.names(host: host, title: need.title, answers: need.options ?? []) else {
                return .refused(DoorCall.Refusal.otherServer.line(by: need.by.agentLabel))
            }
            make = { OwnerStatement.doorMode(fleet: $0, host: host, mode: DoorMode.full.rawValue) }
        }
        guard let make, let fleet = try? await VaultClient().reading(hub: hub, database: database)?.fleetID,
              let key = OwnerKeychain.key(fleet: fleet) else { return .none }
        let statement = make(fleet)
        guard let signature = try? key.sign(statement) else { return .none }
        return .signed(statement: statement, signature: signature)
    }

    /// Why a server's mode was not set, in one plain line for the row.
    enum ModeFailure: LocalizedError, Equatable {
        case notOffered, noOwnerKey, clock
        var errorDescription: String? {
            switch self {
            case .notOffered: "This hub does not take a server's mode yet. Update the hub."
            case .noOwnerKey: "This Mac does not hold the owner key of this fleet, which signs a server's mode."
            case .clock: "This Mac's clock is behind the time of this server's last mode. Set the clock, then try again."
            }
        }
    }

    /// **The owner sets one server to Auto or to Full access** (owner feature `door_mode_set`). This Mac signs the
    /// statement `{v: 1, kind: "door-mode", fleet, host, mode, at}` with the owner key and sends it to
    /// `POST /ui/door/mode`; the hub carries it, and the door takes it at its next refresh, each minute, when the
    /// signature is the owner key's.
    ///
    /// `after` is the server's `mode_at` of `GET /ui/servers`: the statement's time is later than it, because the door
    /// takes only a newer statement. When the hub carries a newer one than the page knew, this signs once more with a
    /// time after that one.
    ///
    /// The receipt says that the hub carries the statement. The server's mode changed when `mode_door` of
    /// `GET /ui/servers` says so: the hub cannot check the signature, only the door can.
    static func setMode(host: String, mode: DoorMode, after: Int? = nil, store: FleetStore, hub: URL,
                        database: String) async throws -> DoorModeReceipt {
        guard store.state?.ui_features?.contains(modeSet) == true else { throw ModeFailure.notOffered }
        guard let fleet = try await VaultClient().reading(hub: hub, database: database)?.fleetID,
              let key = OwnerKeychain.key(fleet: fleet) else { throw ModeFailure.noOwnerKey }
        var newest = after
        for attempt in 0..<2 {
            guard let at = DoorModeCommand.time(now: OwnerStatement.now(), after: newest) else { throw ModeFailure.clock }
            let statement = OwnerStatement.doorMode(fleet: fleet, host: host, mode: mode.rawValue, at: at)
            let signature = try key.sign(statement)
            do {
                return try await VaultClient().doorMode(hub: hub, database: database, client: store.installation,
                                                        host: host, mode: mode, at: at, statement: statement,
                                                        signature: signature)
            } catch let newer as DoorModeCommand.Newer where attempt == 0 {
                newest = max(newer.at, newest ?? newer.at)
            } catch let newer as DoorModeCommand.Newer {
                throw HubError.refusal(409, newer.words)
            }
        }
        throw ModeFailure.clock
    }

    /// A yes from the phone: the phone signs with a key of its own, and this Mac certifies that key with the owner key
    /// once the key's binding matches the one-time value of a QR that this Mac drew (`DeviceBinding`). The Devices
    /// page calls this at each read, so a phone that enrolled from the picture is certified within seconds. Nothing
    /// shows, and a key with no matching value stays uncertified, so its yes lets no door call through.
    static func certify(_ devices: [OwnerDevice], store: FleetStore, hub: URL, database: String) async {
        let signs = store.state?.ui_features?.contains(feature) == true
        let copies = store.state?.ui_features?.contains(RecoveryCopy.feature) == true    // plan V12
        guard signs || copies else { return }
        let pending = devices.filter {
            $0.signing_key != nil && $0.binding != nil && ((signs && !$0.certified) || (copies && $0.wantsRecoveryCopy))
        }
        let binds = pending.isEmpty ? [] : DeviceBinds.all()
        guard !binds.isEmpty, let fleet = try? await VaultClient().reading(hub: hub, database: database)?.fleetID else { return }
        for device in pending {
            guard let key = device.signing_key, let binding = device.binding,
                  let bind = binds.first(where: { DeviceBinding.binding(bind: $0, key: key) == binding }) else { continue }
            var done = true
            if signs && !device.certified {
                let statement = OwnerStatement.ownerDevice(fleet: fleet, device: device.device, key: key)
                done = await { () async -> Bool in
                    guard let owner = OwnerKeychain.key(fleet: fleet), let signature = try? owner.sign(statement) else {
                        return false
                    }
                    return (try? await VaultClient().certifyDevice(hub: hub, database: database, client: store.installation,
                                                                  device: device.device, statement: statement,
                                                                  signature: signature)) != nil
                }()
            }
            // The one-time value goes only once both are done: the copy is checked against the same QR.
            if copies && device.wantsRecoveryCopy {
                let sent = await RecoveryCopy.send(for: device, bind: bind, fleet: fleet, store: store, hub: hub,
                                                   database: database)
                done = done && sent
            }
            if done { DeviceBinds.forget(bind) }
        }
    }
}
