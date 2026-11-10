import FleetCore
import Foundation

/// **The owner's signed yes to a door call** (owner feature `door_calls`, DevOps plan 5.4, decisions D11 and D22).
///
/// The DevOps door refuses a judged call that its judge refused, such as an AWS call that adds cost. The manager takes
/// it to the owner as a Needs-you item that names the call's hash, and the item's first option is the yes. When he
/// presses it, this Mac signs that yes with the owner key that signs his grants, and the answer carries the statement.
/// The door reads it from the hub and checks the signature against the owner key in its own access file, so the hub
/// can hold a yes back and forge none. Nothing shows: a hub without `door_calls`, an item with no door call, another
/// option, or a Mac with no owner key for this fleet sends the answer as before, and the door then refuses the call
/// again.
@MainActor
enum DoorCallSigning {
    static let feature = "door_calls"

    static func approval(for need: OwnerNeed, choice: Int, store: FleetStore, hub: URL,
                         database: String) async -> (statement: String, signature: String)? {
        guard choice == 0, let call = need.door_call, store.state?.ui_features?.contains(feature) == true,
              let fleet = try? await VaultClient().reading(hub: hub, database: database)?.fleetID,
              let key = OwnerKeychain.key(fleet: fleet) else { return nil }
        let statement = OwnerStatement.doorCall(fleet: fleet, need: need.id, call: call)
        guard let signature = try? key.sign(statement) else { return nil }
        return (statement, signature)
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
